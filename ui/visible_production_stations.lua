-- Visible Production Stations (visible_production_stations)
-- Adds a "Visible Production Stations" tab to the Object List panel in the map.
--
-- The tab shows production stations currently visible on the map:
--   - Player-owned stations: full production data with ware breakdown (products,
--     intermediates, resources), per-ware module counts and rate totals.
--   - NPC stations: included with module-count summary. Full ware breakdown is
--     shown when IsInfoUnlockedForPlayer("storage_warelist") returns true.
--     When ware names are not accessible, the expand shows the working/total
--     module count and any issue counts (waiting for resources / waiting for
--     storage) aggregated across all production modules.
--
-- Layout per station row:
--   [+/-] [Station Name / Sector]  [Active/Total Modules]  [LSO button]  [SPO*]
-- Expandable to ware breakdown (products / intermediates / resources) or a
-- limited-info summary with stage-level issue counts.
--
-- Issue highlighting:
--   - Station name icon is tinted warning-colour when any module has issues.
--   - LSO button is tinted warning-colour when issues are present.
--   - Per-ware rows in the expand are tinted when that ware has issues.
--   - Red sub-rows are shown in the limited-info expand for each issue type.
--
-- Compatible with X4 8.00 and 9.00, using RowGroup API on 9.00+.

local ffi = require("ffi")
local C   = ffi.C

ffi.cdef[[
  typedef uint64_t UniverseID;

  typedef struct {
    int major;
    int minor;
  } GameVersion;

  GameVersion GetGameVersion(void);

  bool IsRealComponentClass(UniverseID componentid, const char* classname);
  bool IsComponentWrecked(UniverseID componentid);
  bool IsInfoUnlockedForPlayer(UniverseID containerid, const char* infokey);

  uint32_t GetNumStationModules(UniverseID stationid, bool includeconstructions, bool includewrecks);
  uint32_t GetStationModules(UniverseID* result, uint32_t resultlen, UniverseID stationid, bool includeconstructions, bool includewrecks);

  UniverseID GetPlayerID(void);

  double GetContainerWareConsumption(UniverseID containerid, const char* wareid, bool ignorestate);
  double GetContainerWareProduction(UniverseID containerid, const char* wareid, bool ignorestate);
]]

-- *** constants ***

local PAGE_ID      = 1972092424
local MODE         = "visibleProductionStations"
local TAB_ICON     = "stationbuildst_production"
local SPO_CATEGORY = "chem_station_prod_overview"

-- *** module table ***

local vps = {
  menuMap           = nil,
  menuMapConfig     = {},
  isV9              = C.GetGameVersion().major >= 9,
  mapFontSize       = Helper.standardFontSize,
  hasSPO            = nil,     -- nil = not yet checked; true/false after first render
  showIssuesOnly    = false,   -- set via options menu
  playerId          = nil,     -- set in vps.Init(); used to read MD blackboard config
  -- Data cache keyed by station64 string → { data, turnCounter }
  dataRefreshInterval = 3,
  dataCache           = {},
}

-- *** debug helpers ***

local debugLevel = "none"   -- "none" | "debug" | "trace"

--- Read config from the MD-side player.entity.$visibleProductionStationsConfig blackboard.
--- Called on init and whenever the options menu changes (VisibleProductionStations.ConfigChanged).
local function vpsOnConfigChanged()
  if vps.playerId == nil then return end
  local cfg = GetNPCBlackboard(vps.playerId, "$visibleProductionStationsConfig")
  if cfg then
    vps.showIssuesOnly = (cfg.showIssuesOnly == true or cfg.showIssuesOnly == 1)
    if cfg.debugMode ~= nil then
      debugLevel = cfg.debugMode
    end
    if cfg.dataRefreshInterval ~= nil then
      vps.dataRefreshInterval = math.max(1, math.min(10, tonumber(cfg.dataRefreshInterval) or 3))
      vps.dataCache = {}
    end
  end
end

local function debug(msg)
  if debugLevel ~= "none" and type(DebugError) == "function" then
    DebugError("VisibleProductionStations: " .. msg)
  end
end

local function trace(msg)
  if debugLevel == "trace" then debug(msg) end
end

-- *** formatting helpers ***

local function fmt(n)
  return ConvertIntegerString(Helper.round(n), true, 0, true, false)
end

local function formatProductionTotal(v)
  if Helper.round(v) == 0 then
    return fmt(v)
  elseif v > 0 then
    return ColorText["text_positive"] .. "+" .. fmt(v)
  else
    return ColorText["text_negative"] .. "-" .. fmt(math.abs(v))
  end
end

-- *** data collection ***

--- Collect production module data for one station (player or NPC).
--- Returns nil when:
---   - No production/processing modules found, OR
---   - Player station has no available products or intermediates, OR
---   - No module with readable state data exists (NPC station, data hidden).
---
--- Returns a table with:
---   isNpc        : bool
---   hasWareInfo  : bool   -- true when ware names are visible (always for player)
---   moduleTotal  : int    -- production/processing modules with readable state
---   moduleActive : int    -- modules in "producing" or "choosingitem" state
---   hasIssue     : bool
---   counts       : {
---     intermediate = { noResources=N, waitStorage=N },
---     production   = { noResources=N, waitStorage=N },
---   }
---   moduleCounts : { [ware] = { total, noRes, waitStore } }  (populated when hasWareInfo)
---   resourceWares: { [ware] = true }                         (populated when hasWareInfo)
local function getStationData(luaId, isNpc)
  local station64 = ConvertIDTo64Bit(luaId)

  -- Cache check
  local cacheKey = tostring(station64)
  local cached   = vps.dataCache[cacheKey]
  if cached and cached.turnCounter < vps.dataRefreshInterval then
    cached.turnCounter = cached.turnCounter + 1
    return cached.data
  end

  -- Ware-name visibility: always true for player stations.
  local hasWareInfo = (not isNpc) or C.IsInfoUnlockedForPlayer(station64, "storage_warelist")

  -- For stations where ware names are visible, verify there are actually
  -- production-relevant wares before doing the expensive module scan.
  local productSet      = {}
  local intermediateSet = {}
  if hasWareInfo then
    local availProds, pureRes, interWares =
        GetComponentData(station64, "availableproducts", "pureresources", "intermediatewares")
    availProds  = availProds  or {}
    interWares  = interWares  or {}
    if #availProds == 0 and #interWares == 0 then
      -- No production wares on this station – skip it.
      vps.dataCache[cacheKey] = { data = nil, turnCounter = 1 }
      return nil
    end
    for _, w in ipairs(availProds)  do productSet[w]      = true end
    for _, w in ipairs(interWares)  do intermediateSet[w] = true end
  end

  -- Module scan
  local n = tonumber(C.GetNumStationModules(station64, false, false))
  if not n or n == 0 then
    vps.dataCache[cacheKey] = { data = nil, turnCounter = 1 }
    return nil
  end
  local moduleBuf = ffi.new("UniverseID[?]", n)
  n = tonumber(C.GetStationModules(moduleBuf, n, station64, false, false))

  local hasAnyModule = false
  local moduleTotal  = 0
  local moduleActive = 0

  -- Per-ware module counts (only populated when hasWareInfo = true)
  local moduleCounts = {}
  -- Resource wares consumed by production modules (populated when hasWareInfo)
  local resourceWares = {}

  -- Stage-typed issue type-sets (de-duplicated by "type key" = sorted output wares).
  local types = {
    intermediate = { noResources = {}, waitStorage = {} },
    production   = { noResources = {}, waitStorage = {} },
  }

  for i = 0, n - 1 do
    local mod = ConvertStringTo64Bit(tostring(moduleBuf[i]))
    if IsValidComponent(mod) and not C.IsComponentWrecked(mod) then
      if C.IsRealComponentClass(mod, "production")
          or C.IsRealComponentClass(mod, "processingmodule") then
        local proddata = GetProductionModuleData(mod)
        if proddata then
          -- Only count modules whose state data is accessible.
          hasAnyModule = true
          moduleTotal  = moduleTotal + 1
          local state  = proddata.state

          if state == "producing" or state == "choosingitem" then
            moduleActive = moduleActive + 1
          end

          -- Per-ware counts and resource wares (ware-info path only)
          if hasWareInfo then
            if proddata.products then
              for _, entry in ipairs(proddata.products) do
                local w = entry.ware
                if not moduleCounts[w] then
                  moduleCounts[w] = { total = 0, noRes = 0, waitStore = 0 }
                end
                moduleCounts[w].total = moduleCounts[w].total + 1
                if state == "waitingforresources" then
                  moduleCounts[w].noRes = moduleCounts[w].noRes + 1
                elseif state == "waitingforstorage" or state == "choosingitem" then
                  moduleCounts[w].waitStore = moduleCounts[w].waitStore + 1
                end
              end
            end
            -- Collect static resource wares from module macro library data.
            local macro = GetComponentData(mod, "macro")
            if macro then
              local mData = GetLibraryEntry(GetMacroData(macro, "infolibrary"), macro)
              if mData and mData.products then
                for _, pEntry in ipairs(mData.products) do
                  for _, res in ipairs(pEntry.resources or {}) do
                    resourceWares[res.ware] = true
                  end
                end
              end
            end
          end

          -- Stage-based issue classification (issue = not producing / not choosingitem)
          if state
              and state ~= "empty"
              and state ~= "producing"
              and state ~= "choosingitem" then
            -- Determine stage by whether the module outputs a final product.
            -- When ware info is unavailable, treat all issues as "production".
            local stage = "production"
            if hasWareInfo then
              local mprods = proddata.products or {}
              local producesFinal = false
              for _, entry in ipairs(mprods) do
                if productSet[entry.ware] then
                  producesFinal = true
                  break
                end
              end
              if not producesFinal then
                stage = "intermediate"
              end
            end

            -- Build a stable type key from sorted output wares to de-duplicate
            -- modules of the same type (mirrors production_stations_tab logic).
            local plist = {}
            if proddata.products then
              for _, entry in ipairs(proddata.products) do
                plist[#plist + 1] = entry.ware
              end
            end
            table.sort(plist)
            local typeKey = #plist > 0
                and table.concat(plist, "|")
                or  ("__mod_" .. tostring(mod))

            if state == "waitingforstorage" then
              types[stage].waitStorage[typeKey] = true
            elseif state == "waitingforresources" then
              types[stage].noResources[typeKey] = true
            end
          end
        end
      end
    end
  end

  if not hasAnyModule then
    vps.dataCache[cacheKey] = { data = nil, turnCounter = 1 }
    return nil
  end

  local function countKeys(t)
    local c = 0
    for _ in pairs(t) do c = c + 1 end
    return c
  end

  local counts = {
    intermediate = {
      noResources = countKeys(types.intermediate.noResources),
      waitStorage = countKeys(types.intermediate.waitStorage),
    },
    production = {
      noResources = countKeys(types.production.noResources),
      waitStorage = countKeys(types.production.waitStorage),
    },
  }

  local hasIssue = (
    counts.intermediate.noResources > 0 or
    counts.intermediate.waitStorage > 0 or
    counts.production.noResources   > 0 or
    counts.production.waitStorage   > 0
  )

  local result = {
    isNpc        = isNpc,
    hasWareInfo  = hasWareInfo,
    moduleTotal  = moduleTotal,
    moduleActive = moduleActive,
    hasIssue     = hasIssue,
    counts       = counts,
    moduleCounts = moduleCounts,
    resourceWares= resourceWares,
  }

  vps.dataCache[cacheKey] = { data = result, turnCounter = 1 }
  return result
end

-- *** production wares collection (for expanded ware view) ***

--- Builds the live ware breakdown for a station.
--- Only called when hasWareInfo = true and the station row is expanded.
--- Logic mirrors production_stations_tab.collectProductionWares.
---
--- Returns { products, intermediates, resources } or nil when nothing to show.
local function collectProductionWares(station64, moduleCounts, resourceWares)
  moduleCounts  = moduleCounts  or {}
  resourceWares = resourceWares or {}

  -- Fallback to engine ware lists when the per-module scan returned nothing
  -- (e.g. the station data was collected without a deep module scan).
  if next(moduleCounts) == nil then
    local productWares, pureResources, intermediateWares =
      GetComponentData(station64, "availableproducts", "pureresources", "intermediatewares")
    productWares      = productWares      or {}
    pureResources     = pureResources     or {}
    intermediateWares = intermediateWares or {}
    for _, w in ipairs(productWares)      do moduleCounts[w]  = { total = 0, noRes = 0, waitStore = 0 } end
    for _, w in ipairs(intermediateWares) do moduleCounts[w]  = { total = 0, noRes = 0, waitStore = 0 } end
    for _, w in ipairs(pureResources)     do resourceWares[w] = true end
    for _, w in ipairs(intermediateWares) do resourceWares[w] = true end
  end

  if next(moduleCounts) == nil and next(resourceWares) == nil then return nil end

  local function makeEntry(ware)
    local wareName, wareIcon = GetWareData(ware, "name", "icon")
    local prod    = math.max(0, C.GetContainerWareProduction(station64, ware, false))
    local prodMax = math.max(0, C.GetContainerWareProduction(station64, ware, true))
    local cons    = math.max(0, C.GetContainerWareConsumption(station64, ware, false))
    local mc      = moduleCounts[ware] or { total = 0, noRes = 0, waitStore = 0 }
    local mTotal  = mc.total
    local mActive = 0
    if mTotal > 0 and prodMax > 0 then
      mActive = math.min(mTotal, Helper.round(prod / prodMax * mTotal))
    end
    return {
      name         = wareName or ware,
      icon         = (wareIcon and wareIcon ~= "") and wareIcon or "solid",
      prod         = Helper.round(prod),
      cons         = Helper.round(cons),
      total        = Helper.round(prod - cons),
      moduleTotal  = mTotal,
      moduleActive = mActive,
      noRes        = mc.noRes,
      waitStore    = mc.waitStore,
    }
  end

  local products      = {}
  local intermediates = {}
  local resources     = {}

  -- Wares in moduleCounts: produced by this station.
  -- A produced ware is an "intermediate" when it also appears in resourceWares.
  for ware in pairs(moduleCounts) do
    if resourceWares[ware] then
      table.insert(intermediates, makeEntry(ware))
    else
      table.insert(products, makeEntry(ware))
    end
  end
  table.sort(products,      function(a, b) return a.name < b.name end)
  table.sort(intermediates, function(a, b) return a.name < b.name end)

  -- Resource-only wares: consumed but not produced by this station.
  for ware in pairs(resourceWares) do
    if not moduleCounts[ware] then
      local cons = math.max(0, C.GetContainerWareConsumption(station64, ware, false))
      local rName, rIcon = GetWareData(ware, "name", "icon")
      table.insert(resources, {
        name         = rName or ware,
        icon         = (rIcon and rIcon ~= "") and rIcon or "solid",
        prod         = 0,
        cons         = Helper.round(cons),
        total        = -Helper.round(cons),
        moduleTotal  = 0,
        moduleActive = 0,
        noRes        = 0,
        waitStore    = 0,
      })
    end
  end
  table.sort(resources, function(a, b) return a.name < b.name end)

  if #products == 0 and #intermediates == 0 and #resources == 0 then return nil end
  return { products = products, intermediates = intermediates, resources = resources }
end

-- *** issue text builder ***

--- Builds the mouseover issue text from stage counts.
--- Returns hasIssue (bool), issueText (string).
local function buildIssueText(counts)
  local warnColor  = Helper.convertColorToText(Color["text_warning"])
  local errColor   = Helper.convertColorToText(Color["text_error"])
  local resetColor = "\027X"
  local hasIssue   = false
  local parts      = {}

  local function addSection(titleId, noResCount, waitStoreCount)
    local lines = {}
    if noResCount > 0 then
      hasIssue = true
      lines[#lines + 1] = "  " .. errColor
          .. ReadText(1001, 8431) .. " (" .. noResCount .. ")"
          .. resetColor
    end
    if waitStoreCount > 0 then
      hasIssue = true
      lines[#lines + 1] = "  " .. errColor
          .. ReadText(1001, 8432) .. " (" .. waitStoreCount .. ")"
          .. resetColor
    end
    if #lines > 0 then
      parts[#parts + 1] = warnColor .. ReadText(1001, titleId) .. ":" .. resetColor
          .. "\n" .. table.concat(lines, "\n")
    end
  end

  addSection(6100, counts.intermediate.noResources, counts.intermediate.waitStorage)
  addSection(1610, counts.production.noResources,   counts.production.waitStorage)
  return hasIssue, table.concat(parts, "\n")
end

-- *** tab registration ***

function vps.setupTab()
  local cfg        = vps.menuMapConfig
  local categories = cfg and cfg.objectCategories or nil
  if categories == nil then
    debug("objectCategories not found in menuMapConfig")
    return
  end

  local insertAfter = nil
  local fallbackIdx = nil
  for i, cat in ipairs(categories) do
    if cat.category == MODE then
      trace("tab already registered")
      return
    end
    if cat.category == "stations" then
      insertAfter = i
    end
    if string.sub(cat.category, 1, 10) ~= "custom_tab" then
      fallbackIdx = i
    end
  end

  local idx = insertAfter or fallbackIdx
  if idx then
    table.insert(categories, idx + 1, {
      category = MODE,
      name     = ReadText(PAGE_ID, 1),
      icon     = TAB_ICON,
    })
    trace("tab registered at position " .. tostring(idx + 1))
  end
end

-- *** station row renderer ***

--- Creates a compact two-line row for one production station.
---
--- Column layout (total = 5 + maxIcons):
---   col 1             : +/- expand button
---   col 2, span 3     : Station name / sector (2-line, issue icon tint + mouseover)
---   col 5, span 2     : Active/Total module count (colour-coded)
---   col 7, span 2     : Logical Station Overview button  (when maxIcons >= 3)
---   col 9, span 2     : Station Production Overview btn  (player, hasSPO, maxIcons >= 5)
---
--- Expansion shows:
---   hasWareInfo = true  → ware-group breakdown (Products / Intermediates / Resources)
---                         with per-ware module counts and production rates.
---   hasWareInfo = false → limited-info summary: working/total module count plus
---                         per-stage issue counts (no ware names).
local function createStationRow(instance, ftable, tblOrGroup, luaId, stationData, hasSPO, numdisplayed)
  local menu     = vps.menuMap
  local maxIcons = menu.infoTableData[instance].maxIcons
  local key      = tostring(luaId)
  local comp64   = ConvertIDTo64Bit(luaId)

  local isPlayerOwned = GetComponentData(luaId, "isplayerowned")
  local name, color, bgColor, font, mouseover =
    menu.getContainerNameAndColors(luaId, 0, true, false, true)
  local locationText = GetComponentData(luaId, "sector")

  -- Build issue text from cached stage counts.
  local hasIssue, issueText = false, ""
  if stationData and stationData.counts then
    hasIssue, issueText = buildIssueText(stationData.counts)
  end

  -- Append issue details to the vanilla mouseover text.
  local issueMouseover = mouseover or ""
  if issueText ~= "" then
    if issueMouseover ~= "" then issueMouseover = issueMouseover .. "\n\n" end
    issueMouseover = issueMouseover .. issueText
  end

  -- Tint the embedded icon in the station name when issue is present
  -- (mirrors production_stations_tab createStationRow).
  local displayName = name
  if hasIssue then
    local warningColorText  = Helper.convertColorToText(Color["text_warning"])
    local originalColorText = Helper.convertColorToText(color)
    displayName = name:gsub("(\027%[[^%]]+%])", warningColorText .. "%1\027X" .. originalColorText, 1)
  end

  local displayText = Helper.convertColorToText(color) .. displayName .. "\027X"
      .. "\n" .. (locationText or "")

  -- Module count string, colour-coded by health:
  --   green  = all modules active
  --   yellow = some idle but no error state
  --   red    = one or more modules in error state
  local moduleTotal  = stationData and stationData.moduleTotal  or 0
  local moduleActive = stationData and stationData.moduleActive or 0
  local moduleCountStr = tostring(moduleActive) .. "\n" .. tostring(moduleTotal)

  numdisplayed = numdisplayed + 1

  local row = tblOrGroup:addRow({"property", luaId, nil, 0}, {
    bgColor       = bgColor,
    multiSelected = menu.isSelectedComponent(luaId),
  })
  if menu.isSelectedComponent(luaId) then
    menu.setrow = row.index
  end
  if IsSameComponent(luaId, menu.highlightedbordercomponent) then
    menu.sethighlightborderrow = row.index
  end

  -- Col 1: +/- expand button
  row[1]:createButton({ scaling = false })
        :setText(menu.isPropertyExtended(key) and "-" or "+", { scaling = true, halign = "center" })
  row[1].handlers.onClick = function() return menu.buttonExtendProperty(key) end

  -- Col 2 (span 3): name + sector
  row[2]:setColSpan(3):createText(displayText, { font = font, mouseOverText = issueMouseover })
  local rowHeight = row[2]:getMinTextHeight(true)
  row[1].properties.height = rowHeight

  -- Col 5 (span 2): active/total module count
  row[5]:setColSpan(2):createText(moduleCountStr, { halign = "right", color = hasIssue and Color["text_warning"] or nil })

  -- Col 7 (span 2): Logical Station Overview button
  if maxIcons >= 3 then
    local lsoCell  = row[7]
    lsoCell:setColSpan(2)
    local cellWidth = lsoCell:getWidth()
    local iconSize  = math.min(cellWidth, rowHeight)
    local iconX     = (cellWidth - iconSize) / 2
    local iconY     = (rowHeight - iconSize) / 2
    lsoCell:createButton({ mouseOverText = ReadText(1001, 7903), scaling = false })
        :setIcon("stationbuildst_lsov", {
          scaling = false,
          width   = iconSize, height = iconSize,
          x = iconX, y = iconY,
          color = hasIssue and Color["text_warning"] or nil,
        })
    lsoCell.handlers.onClick = function()
      Helper.closeMenuAndOpenNewMenu(menu, "StationOverviewMenu", { 0, 0, comp64 })
      menu.cleanup()
    end
    lsoCell.properties.height = rowHeight

    -- Col 9 (span 2): Station Production Overview button (player stations only)
    if hasSPO and maxIcons >= 5 then
      local spoCell = row[9]
      spoCell:setColSpan(2)
      spoCell:createButton({ mouseOverText = ReadText(1972092416, 2), scaling = false })
          :setIcon(TAB_ICON, {
            scaling = false,
            width   = iconSize, height = iconSize,
            x = iconX, y = iconY,
            color = hasIssue and Color["text_warning"] or nil,
          })
      spoCell.handlers.onClick = function()
        menu.infoSubmenuObject = comp64
        menu.infoMode["right"] = SPO_CATEGORY
        if menu.searchTableMode == "info" then
          menu.refreshInfoFrame2()
        else
          menu.buttonToggleRightBar("info")
        end
      end
      spoCell.properties.height = rowHeight
    end
  end

  -- *** Expansion ***
  if menu.isPropertyExtended(key) then
    if stationData and stationData.hasWareInfo then
      -- Full ware breakdown -----------------------------------------------
      local wareData = collectProductionWares(
        comp64, stationData.moduleCounts, stationData.resourceWares)

      if wareData then
        -- Column headers
        local chRow = tblOrGroup:addRow(true, Helper.headerRowProperties)
        chRow[1]:setColSpan(2):createText(ReadText(PAGE_ID, 110), Helper.headerRowCenteredProperties)
        chRow[3]:createText(ReadText(PAGE_ID, 112), Helper.headerRowCenteredProperties)
        chRow[4]:createText(ReadText(PAGE_ID, 113), Helper.headerRowCenteredProperties)
        chRow[5]:setColSpan(1 + maxIcons):createText(ReadText(PAGE_ID, 114), Helper.headerRowCenteredProperties)

        local wareIconSize = menu.getShipIconWidth()

        local function renderProdGroup(entries, label)
          if #entries == 0 then return end
          -- Group label row
          local gRow = tblOrGroup:addRow(true, Helper.headerRowProperties)
          gRow[1]:setColSpan(5 + maxIcons):createText(label, Helper.headerRowCenteredProperties)

          for _, entry in ipairs(entries) do
            local dr = tblOrGroup:addRow(true, { bgColor = Color["row_background_unselectable"] })

            -- Module count badge: "A/T" when some are inactive, "T" when all active.
            local countStr = ""
            if entry.moduleTotal > 0 then
              if entry.moduleActive < entry.moduleTotal then
                countStr = tostring(entry.moduleActive) .. "/" .. tostring(entry.moduleTotal)
              else
                countStr = tostring(entry.moduleTotal)
              end
            end

            -- Tint ware name when it has issues (noRes or waitStore).
            local wareHasIssue = (entry.noRes > 0 or entry.waitStore > 0)
            local wareName = wareHasIssue
                and (Helper.convertColorToText(Color["text_warning"]) .. entry.name .. "\027X")
                or  entry.name
            local wareMouseover = ""
            if wareHasIssue then
              local errColor   = Helper.convertColorToText(Color["text_error"])
              local resetColor = "\027X"
              local lines = {}
              if entry.noRes > 0 then
                lines[#lines + 1] = errColor
                    .. ReadText(1001, 8431) .. " (" .. entry.noRes .. ")"
                    .. resetColor
              end
              if entry.waitStore > 0 then
                lines[#lines + 1] = errColor
                    .. ReadText(1001, 8432) .. " (" .. entry.waitStore .. ")"
                    .. resetColor
              end
              wareMouseover = table.concat(lines, "\n")
            end

            -- col 1 (span 2): icon + name (with module count badge on right)
            dr[1]:setColSpan(2)
                :createIcon(entry.icon, {
                  scaling      = false,
                  width        = wareIconSize,
                  height       = wareIconSize,
                  mouseOverText= wareMouseover,
                })
                :setText(wareName, {
                  halign   = "left",
                  x        = wareIconSize + Helper.standardTextOffsetx,
                  fontsize = vps.mapFontSize,
                })
                :setText2(countStr, { halign = "right", fontsize = vps.mapFontSize })

            dr[3]:createText(entry.prod > 0 and fmt(entry.prod) or "--", { halign = "right" })
            dr[4]:createText(entry.cons > 0 and fmt(entry.cons) or "--", { halign = "right" })
            dr[5]:setColSpan(1 + maxIcons):createText(
              formatProductionTotal(entry.total), { halign = "right" })
          end
        end

        renderProdGroup(wareData.products,      ReadText(PAGE_ID, 120))
        renderProdGroup(wareData.intermediates, ReadText(PAGE_ID, 121))
        renderProdGroup(wareData.resources,     ReadText(PAGE_ID, 122))
      else
        -- hasWareInfo = true but no ware data found (unconfigured station, etc.)
        local noteRow = tblOrGroup:addRow(true, { bgColor = Color["row_background_unselectable"] })
        noteRow[2]:setColSpan(4 + maxIcons)
                  :createText(ReadText(PAGE_ID, 1001), { color = Color["text_inactive"] })
      end

    else
      -- Limited info (NPC station, ware names not visible) -----------------
      -- Show working/total module count and per-issue-type row.
      local noteRow = tblOrGroup:addRow(true, { bgColor = Color["row_background_unselectable"] })
      noteRow[2]:setColSpan(4 + maxIcons)
          :createText(
            ReadText(PAGE_ID, 1002)
            .. "  " .. tostring(moduleActive)
            .. "/" .. tostring(moduleTotal),
            { color = Color["text_inactive"] })

      -- Issue rows: one per issue type per stage (red text).
      local counts = stationData and stationData.counts
      if counts then
        local errColor   = Helper.convertColorToText(Color["text_error"])
        local warnColor  = Helper.convertColorToText(Color["text_warning"])
        local resetColor = "\027X"

        local function addIssueSectionRow(titleId, noResCount, waitStoreCount)
          if noResCount == 0 and waitStoreCount == 0 then return end
          local issRow = tblOrGroup:addRow(true, { bgColor = Color["row_background_unselectable"] })
          local parts  = {}
          if noResCount > 0 then
            parts[#parts + 1] = errColor
                .. ReadText(1001, 8431) .. " (" .. noResCount .. ")"
                .. resetColor
          end
          if waitStoreCount > 0 then
            parts[#parts + 1] = errColor
                .. ReadText(1001, 8432) .. " (" .. waitStoreCount .. ")"
                .. resetColor
          end
          issRow[2]:setColSpan(4 + maxIcons)
              :createText(
                warnColor .. ReadText(1001, titleId) .. ":" .. resetColor
                .. "  " .. table.concat(parts, "  "))
        end

        addIssueSectionRow(6100,
          counts.intermediate.noResources, counts.intermediate.waitStorage)
        addIssueSectionRow(1610,
          counts.production.noResources,   counts.production.waitStorage)
      end
    end
  end

  return numdisplayed
end

-- *** display callback ***

--- Main render callback for the "Sector Production" Object List tab.
--- Signature matches createObjectList_on_createPropertySection:
---   callback(numdisplayed, instance, objecttable, infoTableData) -> { numdisplayed }
function vps.displayTabData(numDisplayed, instance, ftable, infoTableData)
  if vps.menuMap == nil then return { numdisplayed = numDisplayed } end
  if vps.menuMap.objectMode ~= MODE then return { numdisplayed = numDisplayed } end
  if infoTableData == nil then return { numdisplayed = numDisplayed } end
  -- Not active in selectCV mode (ship selection overlay).
  if vps.menuMap.mode == "selectCV" then return { numdisplayed = numDisplayed } end

  -- Detect SPO info tab presence once per session.
  if vps.hasSPO == nil then
    vps.hasSPO = false
    local cats = vps.menuMapConfig.infoCategories
    if cats then
      for _, cat in ipairs(cats) do
        if cat.category == SPO_CATEGORY then
          vps.hasSPO = true
          break
        end
      end
    end
  end

  local playerStations = infoTableData.playerStations or {}
  local npcStations    = infoTableData.npcStations    or {}
  local maxIcons       = infoTableData.maxIcons or 5

  -- Collect production station data for all sector-visible stations.
  local playerProd = {}
  local npcProd    = {}

  for _, luaId in ipairs(playerStations) do
    local id64 = ConvertIDTo64Bit(luaId)
    if IsValidComponent(id64) and not C.IsComponentWrecked(id64) then
      local data = getStationData(luaId, false)
      if data then
        if not vps.showIssuesOnly or data.hasIssue then
          table.insert(playerProd, { id = luaId, data = data })
        end
      end
    end
  end

  for _, luaId in ipairs(npcStations) do
    local id64 = ConvertIDTo64Bit(luaId)
    if IsValidComponent(id64) and not C.IsComponentWrecked(id64) then
      local data = getStationData(luaId, true)
      if data then
        if not vps.showIssuesOnly or data.hasIssue then
          table.insert(npcProd, { id = luaId, data = data })
        end
      end
    end
  end

  if not vps.isV9 then
    -- Section header (always shown, even when empty).
    local headerRow = ftable:addRow(false, Helper.headerRowProperties)
    headerRow[1]:setColSpan(5 + maxIcons)
        :createText(ReadText(PAGE_ID, 1), Helper.headerRowCenteredProperties)
    numDisplayed = numDisplayed + 1
  end

  -- RowGroup wrapper (9.00+ API).
  local tblOrGroup = ftable
  if vps.isV9 then
    tblOrGroup = ftable:addRowGroup({})
  end

  local prevDisplayed = numDisplayed

  if #playerProd == 0 and #npcProd == 0 then
    -- Empty state placeholder.
    local emptyRow = tblOrGroup:addRow(MODE, { interactive = false })
    emptyRow[2]:setColSpan(4 + maxIcons):createText(ReadText(PAGE_ID, 1000))
    return { numdisplayed = numDisplayed }
  end

  -- Build a flat list of all station keys for expand/collapse-all.
  local allStationKeys = {}
  for _, entry in ipairs(playerProd) do
    allStationKeys[#allStationKeys + 1] = tostring(entry.id)
  end
  for _, entry in ipairs(npcProd) do
    allStationKeys[#allStationKeys + 1] = tostring(entry.id)
  end

  -- Determine current all-expanded state (true only when every station is expanded).
  local allExpanded = true
  for _, key in ipairs(allStationKeys) do
    if not vps.menuMap.isPropertyExtended(key) then
      allExpanded = false
      break
    end
  end

  -- Column headers (station name / module count).
  local chRow = ftable:addRow("vpsColHeaders", { fixed = true })
  -- col 1: expand/collapse-all button
  chRow[1]:createButton({ scaling = false })
      :setText(allExpanded and "-" or "+", { scaling = true, halign = "center" })
  chRow[1].handlers.onClick = function()
    -- nil = collapsed, true = expanded (isPropertyExtended checks ~= nil)
    local newVal
    if not allExpanded then newVal = true end
    for _, key in ipairs(allStationKeys) do
      vps.menuMap.extendedproperty[key] = newVal
    end
    vps.menuMap.refreshInfoFrame()
  end
  chRow[2]:setColSpan(3):createText(ReadText(PAGE_ID, 110), Helper.headerRowCenteredProperties)
  chRow[5]:setColSpan(maxIcons + 1):createText(ReadText(PAGE_ID, 111), Helper.headerRowCenteredProperties)
  numDisplayed = numDisplayed + 1

  -- Player stations section
  if #playerProd > 0 then
    local secRow = tblOrGroup:addRow(false, Helper.headerRowProperties)
    secRow[1]:setColSpan(5 + maxIcons)
        :createText(ReadText(1001, 3276), Helper.headerRowCenteredProperties)
    for _, entry in ipairs(playerProd) do
      numDisplayed = createStationRow(
        instance, ftable, tblOrGroup, entry.id, entry.data, vps.hasSPO, numDisplayed)
    end
  end

  -- NPC stations section
  if #npcProd > 0 then
    local secRow = tblOrGroup:addRow(false, Helper.headerRowProperties)
    secRow[1]:setColSpan(5 + maxIcons)
        :createText(ReadText(1001, 8302), Helper.headerRowCenteredProperties)
    for _, entry in ipairs(npcProd) do
      numDisplayed = createStationRow(
        instance, ftable, tblOrGroup, entry.id, entry.data, vps.hasSPO, numDisplayed)
    end
  end

  -- Fallback placeholder (should not be reached after the early-out above).
  if numDisplayed == prevDisplayed then
    local emptyRow = tblOrGroup:addRow(MODE, { interactive = false })
    emptyRow[2]:setColSpan(4 + maxIcons):createText(ReadText(PAGE_ID, 1000))
  end

  return { numdisplayed = numDisplayed }
end

function vps.onSelectElement(uitable, modified, row, isdblclick, input)
  debug("onSelectElement called with row " .. tostring(row) .. ", modified: " .. tostring(modified) .. ", isdblclick: " .. tostring(isdblclick))
end

-- *** init ***

function vps.Init(menuMap)
  trace("Init called")
  vps.menuMap       = menuMap
  vps.menuMapConfig = menuMap.uix_getConfig() or {}

  local configFontSize = vps.menuMapConfig.mapFontSize
  vps.mapFontSize = configFontSize
      and Helper.scaleFont(Helper.standardFont, configFontSize)
      or  Helper.standardFontSize

  menuMap.registerCallback(
    "createObjectList_on_createPropertySection",
    vps.displayTabData)
  menuMap.registerCallback("ic_onSelectElement", vps.onSelectElement)
  vps.playerId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
  RegisterEvent("VisibleProductionStations.ConfigChanged", vpsOnConfigChanged)
  vpsOnConfigChanged()

  vps.setupTab()
end

local function Init()
  debug("Initialising Visible Production Stations")

  local menuMap = Helper.getMenu("MapMenu")
  if menuMap == nil or type(menuMap.registerCallback) ~= "function" then
    debug("MapMenu not found – kuertee UI Extensions not loaded?")
    return
  end

  vps.Init(menuMap)
end

Register_OnLoad_Init(Init)
