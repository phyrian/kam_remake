unit KM_HouseMarket;
{$I KaM_Remake.inc}
interface
uses
  KM_Houses,
  KM_ResWares, KM_ResHouses,
  KM_CommonClasses, KM_Defaults;

type
  TKMTradeKind = (tkUnknown, tkExchange, tkTransfer); //FIXME: Use or not?

  //Marketplace
  TKMHouseMarket = class(TKMHouse)
  private
    fResFrom, fResTo: TKMWareType;
    fTransferTo: TKMHouseStore;
    fMarketResIn: array [WARE_MIN..WARE_MAX] of Word;
    fMarketResOut: array [WARE_MIN..WARE_MAX] of Word;
    fMarketDeliveryCount: array [WARE_MIN..WARE_MAX] of Word;
    fHorses: array [1..MAX_WARES_IN_HOUSE] of Pointer;
    fHorseCount: Byte;
    fTradeAmount: Word;
    fTradeKind: TKMTradeKind;
    procedure AttemptExchange;
    procedure SetResFrom(aRes: TKMWareType);
    procedure SetResTo(aRes: TKMWareType);
    procedure SetTransferTo(aStore: TKMHouseStore);

    function GetMarkerResToTrade(aWare: TKMWareType): Word;
    procedure SetMarkerResToTrade(aWare: TKMWareType; aCnt: Word);
    property MarkerResToTrade[aWare: TKMWareType]: Word read GetMarkerResToTrade write SetMarkerResToTrade;
    function GetAvailableHorse: Pointer;
    property AvailableHorse: Pointer read GetAvailableHorse;
  protected
    function GetResOrder(aId: Byte): Integer; override;
    procedure SetResOrder(aId: Byte; aValue: Integer); override;
    procedure CheckTakeOutDeliveryMode; override;
  public
    constructor Create(aUID: Integer; aHouseType: TKMHouseType; PosX, PosY: Integer; aOwner: TKMHandID; aBuildState: TKMHouseBuildState);
    constructor Load(LoadStream: TKMemoryStream); override;

    procedure DemolishHouse(aFrom: TKMHandID; IsSilent: Boolean = False); override;
    property ResFrom: TKMWareType read fResFrom write SetResFrom;
    property ResTo: TKMWareType read fResTo write SetResTo;
    function RatioFrom: Byte;
    function RatioTo: Byte;

    function ShouldAbandonDeliveryFrom(aWareType: TKMWareType; aImmidiateCheck: Boolean = False): Boolean; override;
    function ShouldAbandonDeliveryTo(aWareType: TKMWareType): Boolean; override;

    function AllowedToTrade(aRes: TKMWareType): Boolean;
    function TradeInProgress: Boolean;
    property TradeKind: TKMTradeKind read fTradeKind;
    property TransferTo: TKMHouseStore read fTransferTo write SetTransferTo;
    function GetResTotal(aWare: TKMWareType): Word; overload;
    function CheckResIn(aWare: TKMWareType): Word; override;
    function CheckResOut(aWare: TKMWareType): Word; override;
    procedure ResAddToIn(aResource: TKMWareType; aCount: Integer = 1; aFromScript: Boolean = False); override;
    procedure ResTakeFromOut(aWare: TKMWareType; aCount: Word = 1; aFromScript: Boolean = False); override;
    function ResCanAddToIn(aRes: TKMWareType): Boolean; override;
    function ResOutputAvailable(aRes: TKMWareType; const aCount: Word): Boolean; override;
    procedure CreateHorseInside;

    procedure Save(SaveStream: TKMemoryStream); override;
    procedure Paint; override;
  end;


implementation
uses
  Math, SysUtils, TypInfo,
  KM_RenderPool,
  KM_Hand, KM_HandsCollection, KM_HandLogistics,
  KM_Resource, KM_ResSound,
  KM_ScriptingEvents, KM_Sound, KM_Units;


{ TKMHouseMarket }
constructor TKMHouseMarket.Create(aUID: Integer; aHouseType: TKMHouseType; PosX, PosY: Integer; aOwner: TKMHandID; aBuildState: TKMHouseBuildState);
begin
  inherited;

  fResFrom := wtNone;
  fResTo := wtNone;
  fHorseCount := 0;
end;


procedure TKMHouseMarket.DemolishHouse(aFrom: TKMHandID; IsSilent: Boolean = False);
var
  R: TKMWareType;
begin
  //Count resources as lost
  for R := WARE_MIN to WARE_MAX do
    gHands[fOwner].Stats.WareConsumed(R, fMarketResIn[R] + fMarketResOut[R]);

  //TODO: Horses inside should disappear (without statistics impact!)

  inherited;
end;


function TKMHouseMarket.GetResTotal(aWare: TKMWareType): Word;
begin
  Result := fMarketResIn[aWare] + fMarketResOut[aWare];
end;


function TKMHouseMarket.CheckResIn(aWare: TKMWareType): Word;
begin
  Result := fMarketResIn[aWare];
end;


function TKMHouseMarket.CheckResOut(aWare: TKMWareType): Word;
begin
  Result := fMarketResOut[aWare];
end;


function TKMHouseMarket.GetResOrder(aID: Byte): Integer;
begin
  Result := fTradeAmount;
end;


function TKMHouseMarket.RatioFrom: Byte;
var
  CostFrom, CostTo: Single;
begin
  if (fResFrom <> wtNone) and (fResTo <> wtNone) then
  begin
    //When trading target ware is priced higher
    CostFrom := gRes.Wares[fResFrom].MarketPrice;
    CostTo := gRes.Wares[fResTo].MarketPrice * MARKET_TRADEOFF_FACTOR;
    Result := Round(CostTo / Min(CostFrom, CostTo));
  end else
    Result := 1;
end;


function TKMHouseMarket.RatioTo: Byte;
var CostFrom, CostTo: Single;
begin
  if (fResFrom <> wtNone) and (fResTo <> wtNone) then
  begin
    //When trading target ware is priced higher
    CostFrom := gRes.Wares[fResFrom].MarketPrice;
    CostTo := gRes.Wares[fResTo].MarketPrice * MARKET_TRADEOFF_FACTOR;
    Result := Round(CostFrom / Min(CostFrom, CostTo));
  end else
    Result := 1;
end;


procedure TKMHouseMarket.ResAddToIn(aResource: TKMWareType; aCount: Integer = 1; aFromScript: Boolean = False);
var ResRequired: Integer;
begin
  //If user cancelled the exchange (or began new one with different resources already)
  //then incoming resourced should be added to Offer list immediately
  //We don't want Marketplace to act like a Store
  if not aFromScript then
    Dec(fMarketDeliveryCount[aResource], aCount); //We must keep track of the number ordered, which is less now because this has arrived
  if (aResource = fResFrom) and TradeInProgress then
  begin
    Inc(fMarketResIn[aResource], aCount); //Place the new resource in the IN list
    //As we only order 10 resources at one time, we might need to order another now to fill the gap made by the one delivered
    ResRequired := fTradeAmount*RatioFrom - (fMarketResIn[aResource]+fMarketDeliveryCount[aResource]);
    if ResRequired > 0 then
    begin
      Inc(fMarketDeliveryCount[aResource], Min(aCount, ResRequired));
      gHands[fOwner].Deliveries.Queue.AddDemand(Self, nil, fResFrom, Min(aCount, ResRequired), dtOnce, diNorm);
    end;
    AttemptExchange;
  end
  else
  begin
    Inc(fMarketResOut[aResource], aCount); //Place the new resource in the OUT list
    gHands[fOwner].Deliveries.Queue.AddOffer(Self, aResource, aCount);
  end;
end;


function TKMHouseMarket.ResCanAddToIn(aRes: TKMWareType): Boolean;
begin
  Result := (aRes in [WARE_MIN..WARE_MAX]);
end;


function TKMHouseMarket.ResOutputAvailable(aRes: TKMWareType; const aCount: Word): Boolean;
begin
  Assert(aRes in [WARE_MIN..WARE_MAX]);
  Result := (fMarketResOut[aRes] >= aCount);
end;


procedure TKMHouseMarket.AttemptExchange;
var
  TradeCount: Word;
  PackHorse: TKMUnit;
begin
  Assert((fResFrom <> wtNone) and (((fResTo <> wtNone) and (fResFrom <> fResTo))
          or ((fTransferTo <> nil) and (not fTransferTo.IsDestroyed))));

  //Script might have blocked these resources from trading, if so reset trade order
  if TradeInProgress
  and (not AllowedToTrade(fResFrom) or not AllowedToTrade(fResTo)) then
  begin
    SetResOrder(0, 0);
    Exit;
  end;

  PackHorse := TKMUnit(AvailableHorse);
  if TradeInProgress then
    if ((fResTo <> wtNone) and (MarkerResToTrade[fResFrom] >= RatioFrom)) then //exchange
    begin
      //How much can we trade
      TradeCount := Min((MarkerResToTrade[fResFrom] div RatioFrom), fTradeAmount);

      MarkerResToTrade[fResFrom] := MarkerResToTrade[fResFrom] - TradeCount * RatioFrom;
      gHands[fOwner].Stats.WareConsumed(fResFrom, TradeCount * RatioFrom);
      Dec(fTradeAmount, TradeCount);
      Inc(fMarketResOut[fResTo], TradeCount * RatioTo);
      gHands[fOwner].Stats.WareProduced(fResTo, TradeCount * RatioTo);
      gHands[fOwner].Deliveries.Queue.AddOffer(Self, fResTo, TradeCount * RatioTo);

      gScriptEvents.ProcMarketTrade(Self, fResFrom, fResTo);
      gScriptEvents.ProcWareProduced(Self, fResTo, TradeCount * RatioTo);
      gSoundPlayer.Play(sfxnTrade, fPosition);
    end
    else if (fTransferTo <> nil)
      and (MarkerResToTrade[fResFrom] >= Min(MAX_WARES_ON_HORSE, fTradeAmount))
      and (PackHorse <> nil) then //transfer
    begin
      //How much can we transfer
      TradeCount := Min(MAX_WARES_ON_HORSE, fTradeAmount);

      //Removed ratio as it's "1:1"
      MarkerResToTrade[fResFrom] := MarkerResToTrade[fResFrom] - TradeCount;
      gHands[fOwner].Stats.WareConsumed(fResFrom, TradeCount);
      Dec(fTradeAmount, TradeCount);

      //Start the PackHorse Transfer task
      PackHorse.Transfer(Self, fTransferTo, fResFrom, TradeCount, 0);

      //TODO: Some script event might come here
//      gScriptEvents.ProcMarketTrade(Self, fResFrom, fResTo);
//      gScriptEvents.ProcWareProduced(Self, fResTo, TradeCount * RatioTo);
      gSoundPlayer.Play(sfxnTrade, fPosition);
    end;
end;


procedure TKMHouseMarket.ResTakeFromOut(aWare: TKMWareType; aCount: Word = 1; aFromScript: Boolean = False);
begin
  if aFromScript then
  begin
    aCount := Min(aCount, fMarketResOut[aWare]);
    if aCount > 0 then
    begin
      gHands[fOwner].Stats.WareConsumed(aWare, aCount);
      gHands[fOwner].Deliveries.Queue.RemOffer(Self, aWare, aCount);
    end;
  end;

  if aCount <= fMarketResOut[aWare] then
    Dec(fMarketResOut[aWare], aCount)
  else if (DeliveryMode = dmTakeOut) and (aCount <= fMarketResIn[aWare]) then
    Dec(fMarketResIn[aWare], aCount)
  else
    raise Exception.Create(Format('No ware: [%s] count = %d to take from market UID = %d',
                                  [GetEnumName(TypeInfo(TKMWareType), Integer(aWare)), aCount, UID]));

end;


//Check if we allowed to deliver from Market
//
//Probably this method will be never invoked,
//since when we cancel trade all resources from IN are moved into OUT
//so it looks likewe have no chance to find anything to get in the IN wares, only when trade is going on
function TKMHouseMarket.ShouldAbandonDeliveryFrom(aWareType: TKMWareType; aImmidiateCheck: Boolean = False): Boolean;
begin
  Result := inherited and not ((GetDeliveryModeForCheck(aImmidiateCheck) = dmTakeOut)
                                and (fMarketResIn[aWareType] >= 1));
end;


function TKMHouseMarket.ShouldAbandonDeliveryTo(aWareType: TKMWareType): Boolean;
begin
  Result := inherited or (fTradeAmount = 0) or (fResFrom <> aWareType); //Stop delivery to market when player set trade amount to 0
end;


function TKMHouseMarket.AllowedToTrade(aRes: TKMWareType): Boolean;
begin
  Result := gHands[fOwner].Locks.AllowToTrade[aRes];
end;


procedure TKMHouseMarket.SetResFrom(aRes: TKMWareType);
begin
  if TradeInProgress or not AllowedToTrade(aRes) then
    Exit;

  fResFrom := aRes;
  if fResTo = fResFrom then
    fResTo := wtNone;
end;


procedure TKMHouseMarket.SetResTo(aRes: TKMWareType);
begin
  if TradeInProgress or not AllowedToTrade(aRes) then
    Exit;

  fResTo := aRes;
  fTransferTo := nil;
  if fResFrom = fResTo then
    fResFrom := wtNone;
end;


procedure TKMHouseMarket.SetTransferTo(aStore: TKMHouseStore);
begin
  if TradeInProgress then
    Exit;

  fResTo := wtNone;
  fTransferTo := aStore;
end;


function TKMHouseMarket.GetMarkerResToTrade(aWare: TKMWareType): Word;
begin
  Result := fMarketResIn[aWare] + fMarketResOut[aWare];
end;


procedure TKMHouseMarket.SetMarkerResToTrade(aWare: TKMWareType; aCnt: Word);
var
  CurCnt, DecFromIn, DecFromOut: Word;

begin
  CurCnt := GetMarkerResToTrade(aWare);
  if aCnt > CurCnt then
  begin
    Inc(fMarketResIn[aWare], aCnt - CurCnt);

  end else
  if aCnt < CurCnt then
  begin
    DecFromIn := Min(fMarketResIn[aWare], CurCnt - aCnt);
    Dec(fMarketResIn[aWare], DecFromIn);
    DecFromOut := CurCnt - aCnt - DecFromIn;
    Dec(fMarketResOut[aWare], DecFromOut);
    gHands[fOwner].Deliveries.Queue.RemOffer(Self, aWare, DecFromOut);
  end;
end;


//Maybe not the prettiest solution, trying to look up horses with IsIdle
function TKMHouseMarket.GetAvailableHorse: Pointer;
var
  I: Integer;
begin
  Result := nil;
  for I := 1 to fHorseCount do
    if (fHorses[I] <> nil) and (TKMUnit(fHorses[I]).IsIdle)
        and (TKMUnit(fHorses[I]).InHouse = Self) then
    begin
      Result := fHorses[I];
      break;
    end;
end;


procedure TKMHouseMarket.CreateHorseInside;
var
  I: Integer;
  U: TKMUnit;
begin
  if fHorseCount = MAX_WARES_IN_HOUSE then Exit;

  U := gHands[fOwner].TrainUnit(utRecruit, Entrance);
  U.Visible := False;
  U.InHouse := Self;
  U.Home := Self; //When walking out Home is used to remove recruit from barracks
//  gHands[fOwner].Stats.UnitCreated(utRecruit, False); - No impact on stats

  fHorses[fHorseCount + 1] := U; //Index starts at 1 here
  Inc(fHorseCount);
end;



function TKMHouseMarket.TradeInProgress: Boolean;
begin
  Result := fTradeAmount > 0;
end;


//Player has changed the amount of order
procedure TKMHouseMarket.SetResOrder(aId: Byte; aValue: Integer);
const
  //Maximum number of Demands we can place at once (stops the delivery queue from becoming clogged with 1500 items)
  MAX_RES_ORDERED = 10;
var
  ResRequired, OrdersAllowed, OrdersRemoved: Integer;
begin
  if (fResFrom = wtNone) or ((fResTo = wtNone) and (fTransferTo = nil)) or (fResFrom = fResTo) then Exit;

  fTradeAmount := EnsureRange(aValue, 0, MAX_WARES_ORDER);

  //Try to make an exchange from existing resources
  AttemptExchange;

  //If player cancelled exchange then move all remainders of From resource to Offers list
  if (fTradeAmount = 0) and (fMarketResIn[fResFrom] > 0) then
  begin
    Inc(fMarketResOut[fResFrom], fMarketResIn[fResFrom]);
    gHands[fOwner].Deliveries.Queue.AddOffer(Self, fResFrom, fMarketResIn[fResFrom]);
    fMarketResIn[fResFrom] := 0;
  end;

  //@Lewin: If player has cancelled the exchange and then started it again resources will not be
  //removed from offers list and perhaps serf will carry them off the marketplace
  //@Krom: Yes. It would be better if the deliveries were abandoned and the resources were use in
  //the new trade. For example I might be trading stone to bread, then cancel and change from stone to wine.
  //I would expect any stone already at the marketplace to stay since the new trade requires it,
  //it looks bad that serfs remove the stone then take it back. To be converted to todo item.

  //How much do we need to ask to add to delivery system = Needed - (Ordered + Arrived)
  ResRequired := (fTradeAmount * RatioFrom - (fMarketDeliveryCount[fResFrom]+fMarketResIn[fResFrom]));
  OrdersAllowed := MAX_RES_ORDERED - fMarketDeliveryCount[fResFrom];

  Assert(OrdersAllowed >= 0); //We must never have ordered more than we are allowed

  //Order as many as we can within our limit
  if (ResRequired > 0) and (OrdersAllowed > 0) then
  begin
    Inc(fMarketDeliveryCount[fResFrom], Min(ResRequired,OrdersAllowed));
    gHands[fOwner].Deliveries.Queue.AddDemand(Self, nil, fResFrom, Min(ResRequired,OrdersAllowed), dtOnce, diNorm)
  end
  else
    //There are too many resources ordered, so remove as many as we can from the delivery list (some will be being performed)
    if (ResRequired < 0) then
    begin
      OrdersRemoved := gHands[fOwner].Deliveries.Queue.TryRemoveDemand(Self, fResFrom, -ResRequired);
      Dec(fMarketDeliveryCount[fResFrom], OrdersRemoved);
    end;
end;


//Check and proceed if we Set or UnSet dmTakeOut delivery mode
procedure TKMHouseMarket.CheckTakeOutDeliveryMode;
var
  WT: TKMWareType;
begin
  if DeliveryMode = dmTakeOut then
    for WT := WARE_MIN to WARE_MAX do
    begin
      if fMarketResIn[WT] > 0 then
        gHands[fOwner].Deliveries.Queue.RemOffer(Self, WT, fMarketResIn[WT]);
    end;

  if NewDeliveryMode = dmTakeOut then
  begin
    for WT := WARE_MIN to WARE_MAX do
    begin
      if fMarketResIn[WT] > 0 then
        gHands[fOwner].Deliveries.Queue.AddOffer(Self, WT, fMarketResIn[WT]);
    end;
  end;
end;


//TODO: New props
constructor TKMHouseMarket.Load(LoadStream: TKMemoryStream);
begin
  inherited;
  LoadStream.CheckMarker('HouseMarket');
  LoadStream.Read(fTradeAmount);
  LoadStream.Read(fResFrom, SizeOf(fResFrom));
  LoadStream.Read(fResTo, SizeOf(fResTo));
  LoadStream.Read(fMarketResIn, SizeOf(fMarketResIn));
  LoadStream.Read(fMarketResOut, SizeOf(fMarketResOut));
  LoadStream.Read(fMarketDeliveryCount, SizeOf(fMarketDeliveryCount));
end;


//TODO: New props
procedure TKMHouseMarket.Save(SaveStream: TKMemoryStream);
begin
  inherited;
  SaveStream.PlaceMarker('HouseMarket');
  SaveStream.Write(fTradeAmount);
  SaveStream.Write(fResFrom, SizeOf(fResFrom));
  SaveStream.Write(fResTo, SizeOf(fResTo));
  SaveStream.Write(fMarketResIn, SizeOf(fMarketResIn));
  SaveStream.Write(fMarketResOut, SizeOf(fMarketResOut));
  SaveStream.Write(fMarketDeliveryCount, SizeOf(fMarketDeliveryCount));
end;


//Render special market wares display
procedure TKMHouseMarket.Paint;
var
  R: TKMWareType;
  MaxCount: Word;
  MaxRes: TKMWareType;
begin
  inherited;
  if fBuildState < hbsDone then Exit;

  //Market can display only one ware at a time (lookup ware that has most count)
  MaxCount := 0;
  MaxRes := wtNone;
  for R := WARE_MIN to WARE_MAX do
  if fMarketResIn[R] + fMarketResOut[R] > MaxCount then
  begin
    MaxCount := fMarketResIn[R] + fMarketResOut[R];
    MaxRes := R;
  end;

  if MaxCount > 0 then
    //FlagAnimStep is required for horses animation
    gRenderPool.AddHouseMarketSupply(fPosition, MaxRes, MaxCount, FlagAnimStep);
end;


end.
