-- DungeonPosition: a small map window that shows the player's position inside dungeons.
--
-- How it works:
--   C_Map.GetPlayerMapPosition / UnitPosition return nil inside instances (restriction since patch 7.1.0),
--   so an addon cannot read the player's coordinates there. The player arrow on Blizzard maps is drawn
--   by the engine widget UnitPositionFrame (GroupMembersPinTemplate), which positions units itself.
--   This addon builds its own map canvas (same way as Blizzard_BattlefieldMap) and puts that engine
--   widget on it, so the client draws the arrow. The addon never needs the coordinates.

local ADDON_NAME = ...;

local PREFIX = "|cff33ff99DungeonPosition|r: ";

local DEFAULTS = {
	auto = true,        -- open automatically in dungeons/raids, close when leaving
	locked = false,     -- forbid moving/resizing
	alpha = 1.0,        -- window opacity
	scale = 1.0,        -- window scale
	showGroup = true,   -- show party/raid members as dots
	forceArrow = true,  -- show the arrow even on maps flagged "hide icons"
	width = 320,
	height = 230,
	point = nil,        -- { point, relativePoint, x, y }
};

local PLAYER_PIN_SIZE = 22;
local GROUP_PIN_SIZE = 10;

local db;
local mapFrame;
local groupProvider;
local autoShown = false; -- the window was opened by auto mode (so auto mode may also close it)

local function Print(msg)
	print(PREFIX .. msg);
end

local function CopyDefaults(src, dst)
	for k, v in pairs(src) do
		if dst[k] == nil then
			dst[k] = v;
		end
	end
end

local function IsInDungeonOrRaid()
	local inInstance, instanceType = IsInInstance();
	return inInstance and (instanceType == "party" or instanceType == "raid" or instanceType == "scenario");
end

-- Lowest map with art that contains the player (the current dungeon floor when inside a dungeon).
-- If the map API gives nothing, fall back to the map the minimap is using (C_Minimap.GetUiMapID).
local function GetPlayerDisplayMap()
	local mapID = C_Map.GetBestMapForUnit("player");
	if not mapID and C_Minimap and C_Minimap.GetUiMapID then
		mapID = C_Minimap.GetUiMapID();
	end
	while mapID and mapID ~= 0 do
		if C_Map.MapHasArt(mapID) then
			return mapID;
		end
		local info = C_Map.GetMapInfo(mapID);
		mapID = info and info.parentMapID or 0;
	end
	return nil;
end

-- "Map name — floor name" (floor name only when the map belongs to a multi-floor group).
local function GetMapTitle(mapID)
	local info = mapID and C_Map.GetMapInfo(mapID);
	if not info then
		return UNKNOWN or "?";
	end
	local title = info.name;
	local groupID = C_Map.GetMapGroupID(mapID);
	if groupID then
		local floors = C_Map.GetMapGroupMembersInfo(groupID);
		if floors and #floors > 1 then
			for _, floor in ipairs(floors) do
				if floor.mapID == mapID and floor.name and floor.name ~= "" and floor.name ~= title then
					title = title .. " — " .. floor.name;
					break;
				end
			end
		end
	end
	return title;
end

--------------------------------------------------------------------------------
-- Data provider: Blizzard's group-members provider (engine-drawn arrow + party dots)
--------------------------------------------------------------------------------

-- Same as GroupMembersPinMixin:OnMapChanged, but optionally ignores the map's "hideIcons" flag.
local function PinOnMapChanged(pin)
	local mapID = pin:GetMap():GetMapID();
	if not mapID then
		return;
	end
	local hideMapIcons = C_Map.GetMapDisplayInfo(mapID);
	if hideMapIcons and not db.forceArrow then
		pin:Hide();
		return;
	end
	pin:SetUiMapID(mapID);
	pin:Show();
	if pin.dataProvider:ShouldShowUnit("player") then
		pin:StartPlayerPing(2, 0.25);
	end
end

-- Built lazily (at PLAYER_LOGIN), when GroupMembersDataProviderMixin is guaranteed to exist.
local function CreateGroupProvider()
	local provider = CreateFromMixins(GroupMembersDataProviderMixin);
	function provider:OnAdded(mapCanvas)
		GroupMembersDataProviderMixin.OnAdded(self, mapCanvas);
		-- Instance field overrides the mixin method for this pin only (it belongs to our canvas).
		self.pin.OnMapChanged = PinOnMapChanged;
	end
	return provider;
end

local function ApplyGroupVisibility()
	if not groupProvider then
		return;
	end
	local size = db.showGroup and GROUP_PIN_SIZE or 0;
	groupProvider:SetUnitPinSize("party", size);
	groupProvider:SetUnitPinSize("raid", size);
	if groupProvider.pin then
		groupProvider.pin:SynchronizePinSizes();
	end
end

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------

local function SavePosition()
	local point, _, relativePoint, x, y = mapFrame:GetPoint(1);
	db.point = { point, relativePoint, x, y };
	db.width, db.height = mapFrame:GetSize();
end

local function ApplyPosition()
	mapFrame:ClearAllPoints();
	if db.point then
		mapFrame:SetPoint(db.point[1], UIParent, db.point[2], db.point[3], db.point[4]);
	else
		mapFrame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -230, -40);
	end
	mapFrame:SetSize(db.width, db.height);
end

local function ApplyAppearance()
	mapFrame:SetScale(db.scale);
	mapFrame:SetAlpha(db.alpha);
	mapFrame.ResizeGrip:SetShown(not db.locked);
end

local function UpdateMap()
	if not mapFrame then
		return;
	end
	local mapID = GetPlayerDisplayMap();
	if mapID and C_Map.MapHasArt(mapID) then
		mapFrame:SetMapID(mapID);
		mapFrame.TitleBar.Text:SetText(GetMapTitle(mapID));
	else
		if not mapFrame:GetMapID() then
			mapFrame:SetMapID(C_Map.GetFallbackWorldMapID());
		end
		mapFrame.TitleBar.Text:SetText("Нет карты для этой локации");
	end
end

local function ShowWindow()
	if not mapFrame then
		return;
	end
	UpdateMap();
	mapFrame:Show();
end

local function HideWindow()
	if mapFrame then
		mapFrame:Hide();
	end
	autoShown = false;
end

local function CreateMapWindow()
	if not (MapCanvasMixin and GroupMembersDataProviderMixin and C_XMLUtil.GetTemplateInfo("MapCanvasFrameTemplate")) then
		Print("не найден код карты Blizzard (Blizzard_MapCanvas / Blizzard_SharedMapDataProviders). Аддон отключён.");
		return;
	end

	mapFrame = CreateFrame("Frame", "DungeonPositionFrame", UIParent, "DungeonPositionFrameTemplate");
	-- MapCanvasMixin:OnLoad has already run inside CreateFrame.
	mapFrame:SetDontSavePosition(true); -- position is stored in DungeonPositionDB, not layout-local.txt

	mapFrame:SetShouldZoomInOnClick(false);
	mapFrame:SetShouldPanOnClick(false);
	mapFrame:SetShouldNavigateOnClick(false);
	mapFrame:SetShouldZoomInstantly(true);

	local levels = mapFrame:GetPinFrameLevelsManager();
	levels:AddFrameLevel("PIN_FRAME_LEVEL_MAP_EXPLORATION");
	levels:AddFrameLevel("PIN_FRAME_LEVEL_GROUP_MEMBER");

	if MapExplorationDataProviderMixin then
		mapFrame:AddDataProvider(CreateFromMixins(MapExplorationDataProviderMixin));
	end

	groupProvider = CreateGroupProvider();
	groupProvider:SetUnitPinSize("player", PLAYER_PIN_SIZE);
	groupProvider:SetUnitPinSize("party", GROUP_PIN_SIZE);
	groupProvider:SetUnitPinSize("raid", GROUP_PIN_SIZE);
	mapFrame:AddDataProvider(groupProvider);

	-- Background + border behind the canvas.
	local border = CreateFrame("Frame", nil, mapFrame, "BackdropTemplate");
	border:SetAllPoints();
	border:SetFrameLevel(math.max(mapFrame:GetFrameLevel() - 1, 0));
	border:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 14,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	});
	border:SetBackdropColor(0, 0, 0, 0.85);
	border:SetBackdropBorderColor(0.6, 0.6, 0.6, 1);

	-- Moving by the title bar.
	local titleBar = mapFrame.TitleBar;
	titleBar:RegisterForDrag("LeftButton");
	titleBar:SetScript("OnDragStart", function()
		if not db.locked then
			mapFrame:StartMoving();
		end
	end);
	titleBar:SetScript("OnDragStop", function()
		mapFrame:StopMovingOrSizing();
		SavePosition();
	end);
	titleBar:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP");
		GameTooltip:SetText("DungeonPosition");
		GameTooltip:AddLine("Тащите заголовок, чтобы переместить окно.", 1, 1, 1);
		GameTooltip:AddLine("Колесо мыши над картой — масштаб.", 1, 1, 1);
		GameTooltip:AddLine("/dpos — команды", 1, 1, 1);
		GameTooltip:Show();
	end);
	titleBar:SetScript("OnLeave", GameTooltip_Hide);

	titleBar.CloseButton:SetScript("OnClick", function()
		HideWindow();
		-- Don't reopen automatically until the player leaves this instance.
		mapFrame.closedByUserHere = IsInDungeonOrRaid() or nil;
	end);

	-- Resizing.
	mapFrame:SetResizeBounds(180, 140, 900, 700);
	local grip = mapFrame.ResizeGrip;
	grip:SetFrameLevel(mapFrame.ScrollContainer:GetFrameLevel() + 20);
	grip:SetScript("OnMouseDown", function()
		if not db.locked then
			mapFrame:StartSizing("BOTTOMRIGHT");
		end
	end);
	grip:SetScript("OnMouseUp", function()
		mapFrame:StopMovingOrSizing();
		SavePosition();
	end);
	mapFrame:SetScript("OnSizeChanged", function(self)
		self:OnFrameSizeChanged();
	end);

	ApplyPosition();
	ApplyAppearance();
	ApplyGroupVisibility();
end

--------------------------------------------------------------------------------
-- Auto show / map following
--------------------------------------------------------------------------------

local function OnZoneChanged()
	if not mapFrame then
		return;
	end
	if IsInDungeonOrRaid() then
		if db.auto and not mapFrame:IsShown() and not mapFrame.closedByUserHere then
			autoShown = true;
			ShowWindow();
			return;
		end
	else
		mapFrame.closedByUserHere = nil;
		if autoShown then
			HideWindow();
			return;
		end
	end
	if mapFrame:IsShown() then
		UpdateMap();
	end
end

--------------------------------------------------------------------------------
-- Diagnostics (/dpos check)
--------------------------------------------------------------------------------

local function ValueText(v)
	if v == nil then
		return "|cffff5555nil|r";
	end
	return "|cffffffff" .. tostring(v) .. "|r";
end

local function MapTypeName(mapType)
	if Enum and Enum.UIMapType then
		for name, value in pairs(Enum.UIMapType) do
			if value == mapType then
				return name;
			end
		end
	end
	return tostring(mapType);
end

local function RunCheck()
	Print("--- проверка ---");
	local inInstance, instanceType = IsInInstance();
	local instName, _, _, difficultyName, _, _, _, instanceID = GetInstanceInfo();
	Print(("Инстанс: %s, тип: %s, название: %s, сложность: %s, instanceID: %s"):format(
		ValueText(inInstance), ValueText(instanceType), ValueText(instName), ValueText(difficultyName), ValueText(instanceID)));

	local bestMap = C_Map.GetBestMapForUnit("player");
	local bestInfo = bestMap and C_Map.GetMapInfo(bestMap);
	Print(("GetBestMapForUnit: %s (%s, тип %s), есть арт: %s"):format(
		ValueText(bestMap), ValueText(bestInfo and bestInfo.name), ValueText(bestInfo and MapTypeName(bestInfo.mapType)),
		ValueText(bestMap and C_Map.MapHasArt(bestMap))));

	if C_Minimap and C_Minimap.GetUiMapID then
		local mmMap = C_Minimap.GetUiMapID();
		local mmInfo = mmMap and C_Map.GetMapInfo(mmMap);
		Print(("Карта миникарты (C_Minimap.GetUiMapID): %s (%s)"):format(ValueText(mmMap), ValueText(mmInfo and mmInfo.name)));
	end

	local displayMap = GetPlayerDisplayMap();
	local displayInfo = displayMap and C_Map.GetMapInfo(displayMap);
	Print(("Показываемая карта: %s (%s)"):format(ValueText(displayMap), ValueText(displayInfo and displayInfo.name)));

	if displayMap then
		local ok, hideIcons = pcall(C_Map.GetMapDisplayInfo, displayMap);
		Print("GetMapDisplayInfo hideIcons: " .. (ok and ValueText(hideIcons) or ("ошибка: " .. tostring(hideIcons))));

		local okPos, pos = pcall(C_Map.GetPlayerMapPosition, displayMap, "player");
		if not okPos then
			Print("GetPlayerMapPosition: ошибка: " .. tostring(pos));
		elseif pos then
			local x, y = pos:GetXY();
			Print(("GetPlayerMapPosition: %.1f, %.1f (координаты доступны аддонам)"):format(x * 100, y * 100));
		else
			Print("GetPlayerMapPosition: " .. ValueText(nil) .. " (координаты закрыты для аддонов — это ожидаемо в инстансе)");
		end
	end

	if mapFrame then
		local pin = groupProvider and groupProvider.pin;
		Print(("Окно: %s, карта окна: %s, стрелка (pin) показана: %s"):format(
			ValueText(mapFrame:IsShown()), ValueText(mapFrame:GetMapID()), ValueText(pin and pin:IsShown())));
	else
		Print("Окно не создано.");
	end
	Print(("Настройки: auto=%s, lock=%s, group=%s, forcearrow=%s, alpha=%.2f, scale=%.2f"):format(
		tostring(db.auto), tostring(db.locked), tostring(db.showGroup), tostring(db.forceArrow), db.alpha, db.scale));
end

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

local function OnOff(v)
	return v and "|cff55ff55вкл|r" or "|cffff5555выкл|r";
end

local function PrintHelp()
	Print("команды:");
	print("  /dpos — показать/скрыть окно карты");
	print("  /dpos auto — авто-открытие в подземельях: " .. OnOff(db.auto));
	print("  /dpos lock — закрепить окно: " .. OnOff(db.locked));
	print("  /dpos group — показывать группу: " .. OnOff(db.showGroup));
	print("  /dpos forcearrow — стрелка даже на картах с флагом «скрыть значки»: " .. OnOff(db.forceArrow));
	print(("  /dpos alpha 0.2-1 — прозрачность (сейчас %.2f)"):format(db.alpha));
	print(("  /dpos scale 0.5-2 — размер (сейчас %.2f)"):format(db.scale));
	print("  /dpos reset — вернуть положение и размер по умолчанию");
	print("  /dpos check — диагностика (пришлите вывод, если что-то не работает)");
end

SLASH_DUNGEONPOSITION1 = "/dpos";
SLASH_DUNGEONPOSITION2 = "/dungeonposition";
SlashCmdList["DUNGEONPOSITION"] = function(msg)
	if not db then
		return;
	end
	local cmd, arg = strsplit(" ", strtrim(msg or ""):lower(), 2);
	if cmd == "" then
		if not mapFrame then
			Print("окно не создано, см. сообщения выше.");
		elseif mapFrame:IsShown() then
			HideWindow();
			mapFrame.closedByUserHere = IsInDungeonOrRaid() or nil;
		else
			autoShown = false;
			ShowWindow();
		end
	elseif cmd == "auto" then
		db.auto = not db.auto;
		Print("авто-открытие в подземельях: " .. OnOff(db.auto));
	elseif cmd == "lock" then
		db.locked = not db.locked;
		if mapFrame then ApplyAppearance(); end
		Print("окно закреплено: " .. OnOff(db.locked));
	elseif cmd == "group" then
		db.showGroup = not db.showGroup;
		ApplyGroupVisibility();
		Print("показ группы: " .. OnOff(db.showGroup));
	elseif cmd == "forcearrow" then
		db.forceArrow = not db.forceArrow;
		if mapFrame and groupProvider and groupProvider.pin and mapFrame:GetMapID() then
			groupProvider.pin:OnMapChanged();
		end
		Print("стрелка на картах с флагом «скрыть значки»: " .. OnOff(db.forceArrow));
	elseif cmd == "alpha" or cmd == "scale" then
		local value = tonumber(arg);
		local minV, maxV = (cmd == "alpha") and 0.2 or 0.5, (cmd == "alpha") and 1 or 2;
		if not value or value < minV or value > maxV then
			Print(("укажите число от %s до %s, например /dpos %s %s"):format(minV, maxV, cmd, maxV));
			return;
		end
		db[cmd] = value;
		if mapFrame then ApplyAppearance(); end
		Print(("%s = %.2f"):format(cmd, value));
	elseif cmd == "reset" then
		db.point = nil;
		db.width, db.height = DEFAULTS.width, DEFAULTS.height;
		db.scale, db.alpha = DEFAULTS.scale, DEFAULTS.alpha;
		if mapFrame then
			ApplyPosition();
			ApplyAppearance();
		end
		Print("положение и размер сброшены.");
	elseif cmd == "check" then
		RunCheck();
	else
		PrintHelp();
	end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local events = CreateFrame("Frame");
events:RegisterEvent("ADDON_LOADED");
events:RegisterEvent("PLAYER_LOGIN");
events:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON_NAME then
			DungeonPositionDB = DungeonPositionDB or {};
			db = DungeonPositionDB;
			CopyDefaults(DEFAULTS, db);
			self:UnregisterEvent("ADDON_LOADED");
		end
	elseif event == "PLAYER_LOGIN" then
		CreateMapWindow();
		if mapFrame then
			self:RegisterEvent("PLAYER_ENTERING_WORLD");
			self:RegisterEvent("ZONE_CHANGED_NEW_AREA");
			self:RegisterEvent("ZONE_CHANGED");
			self:RegisterEvent("ZONE_CHANGED_INDOORS");
			self:RegisterEvent("NEW_WMO_CHUNK");
			OnZoneChanged();
		end
	else
		OnZoneChanged();
	end
end);
