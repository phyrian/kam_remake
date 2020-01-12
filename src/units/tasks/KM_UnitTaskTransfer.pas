unit KM_UnitTaskTransfer;
{$I KaM_Remake.inc}
interface
uses
  Classes, SysUtils,
  KM_CommonClasses, KM_Points, KM_Houses,
  KM_HouseMarket, KM_Units, KM_ResWares;


type
  TKMTransferStage = (tsUnknown,
                     tsToStart,         //PackHorse is walking to the offer house
                     tsAtStart,         //PackHorse is operating with the offer house
                     tsToDestination,   //PackHorse is walking to the target house
                     tsAtDestination,   //PackHorse is operating with the target house
                     tsToReturn,        //PackHorse is walking back to the offer house
                     tsAtReturn         //PackHorse is getting in to the offer house
                     );

  TKMTaskTransfer = class(TKMUnitTask)
  private
    fFrom: TKMHouseMarket; //A market
    fTo: TKMHouseStore; //A storehouse
    fWareType: TKMWareType;
    fWareAmount: Word;
    fTransferID: Integer;
    fPointBelowToHouse: TKMPoint; //Have to save that point separately, in case ToHouse will be destroyed
    fPointBelowFromHouse: TKMPoint; //Have to save that point separately, in case FromHouse will be destroyed
    function GetTransferStage: TKMTransferStage;
    procedure SetFromHouse(aFromHouse: TKMHouseMarket);
    procedure SetToHouse(aToHouse: TKMHouseStore);
    property FromHouse: TKMHouseMarket read fFrom write SetFromHouse;
    property ToHouse: TKMHouseStore read fTo write SetToHouse;
  public
    //FIXME: Unit type
    constructor Create(aHorse: TKMUnit; aFrom: TKMHouseMarket; aTo: TKMHouseStore; Res: TKMWareType; Amount: Word; aID: Integer); overload;
    constructor Load(LoadStream: TKMemoryStream); override;
    procedure SyncLoad; override;
    destructor Destroy; override;
    function WalkShouldAbandon: Boolean; override;
    property TransferStage: TKMTransferStage read GetTransferStage;
    function Execute: TKMTaskResult; override;
    function CouldBeCancelled: Boolean; override;
    procedure Save(SaveStream: TKMemoryStream); override;

    function ObjToString(aSeparator: String = ', '): String; override;

    procedure Paint; override; //Used only for debug so far
  end;


implementation
uses
  Math, TypInfo,
  KM_Defaults, KM_HandsCollection, KM_Hand,
  KM_Terrain, KM_Log, KM_RenderAux,
  KM_ResHouses, KM_ResSound,
  KM_ScriptingEvents, KM_Sound;


{ TTaskTransfer }
constructor TKMTaskTransfer.Create(aHorse: TKMUnit; aFrom: TKMHouseMarket; aTo: TKMHouseStore; Res: TKMWareType; Amount: Word; aID: Integer);
begin
  inherited Create(aHorse);
  fType := uttTransfer;

  Assert((aFrom <> nil) and (aTo <> nil) and (Res <> wtNone) and (Amount <= MAX_WARES_ON_HORSE), 'PackHorse ' + IntToStr(fUnit.UID) + ': invalid Transfer task');

  //FIXME: Change it to Transfer log
  if gLog.CanLogDelivery then
    gLog.LogDelivery('PackHorse ' + IntToStr(fUnit.UID) + ' created Transfer task ' + IntToStr(fTransferID));

  FromHouse := TKMHouseMarket(aFrom.GetHousePointer); //Also will set fPointBelowFromHouse
  ToHouse := TKMHouseStore(aTo.GetHousePointer); //Also will set fPointBelowToHouse

  fWareType   := Res;
  fWareAmount := Amount;
  fTransferID  := aID;
end;


constructor TKMTaskTransfer.Load(LoadStream: TKMemoryStream);
begin
  inherited;
  LoadStream.CheckMarker('TaskTransfer');
  LoadStream.Read(fFrom, 4);
  LoadStream.Read(fTo, 4);
  LoadStream.Read(fPointBelowToHouse);
  LoadStream.Read(fPointBelowFromHouse);
  LoadStream.Read(fWareType, SizeOf(fWareType));
  LoadStream.Read(fWareAmount);
  LoadStream.Read(fTransferID);
end;



procedure TKMTaskTransfer.Save(SaveStream: TKMemoryStream);
begin
  inherited;
  SaveStream.PlaceMarker('TaskTransfer');
  if fFrom <> nil then
    SaveStream.Write(fFrom.UID) //Store ID, then substitute it with reference on SyncLoad
  else
    SaveStream.Write(Integer(0));
  if fTo <> nil then
    SaveStream.Write(fTo.UID) //Store ID, then substitute it with reference on SyncLoad
  else
    SaveStream.Write(Integer(0));
  SaveStream.Write(fPointBelowToHouse);
  SaveStream.Write(fPointBelowFromHouse);
  SaveStream.Write(fWareType, SizeOf(fWareType));
  SaveStream.Write(fWareAmount);
  SaveStream.Write(fTransferID);
end;


procedure TKMTaskTransfer.SyncLoad;
begin
  inherited;
  fFrom := TKMHouseMarket(gHands.GetHouseByUID(Cardinal(fFrom)));
  fTo   := TKMHouseStore(gHands.GetHouseByUID(Cardinal(fTo)));
end;


//TODO
destructor TKMTaskTransfer.Destroy;
begin
  //FIXME: Change it to Transfer log
  if gLog.CanLogDelivery then
    gLog.LogDelivery('PackHorse ' + IntToStr(fUnit.UID) + ' abandoned Transfer task ' + IntToStr(fTransferID) + ' at phase ' + IntToStr(fPhase));


  //TODO: logistics for transfer?
  if fUnit <> nil then
  begin
//    if fTransferID <> 0 then
//      gHands[fUnit.Owner].Transfers.Queue.AbandonTransfer(fTransferID);

//    if TKMUnitSerf(fUnit).Carry <> wtNone then
//    begin
//      gHands[fUnit.Owner].Stats.WareConsumed(TKMUnitSerf(fUnit).Carry, fWareAmount);
//      TKMUnitSerf(fUnit).CarryTake; //empty hands
//    end;
  end;

  gHands.CleanUpHousePointer(TKMHouse(fFrom));
  gHands.CleanUpHousePointer(TKMHouse(fTo));
  inherited;
end;


//Note: Phase is -1 because it will have been increased at the end of last Execute
function TKMTaskTransfer.WalkShouldAbandon: Boolean;
begin
  Result := False;

  if fPhase2 <> 0 then //we are at 'go to road' stage, no need to cancel that action
    Exit;

//  if fPhase >= 2 and fPhase <= 6 then //onwards
//      Result := Result or fTo.IsDestroyed;
//
//  if fPhase <= 2 or fPhase >= 8 then //backwards
//      Result := Result or fFrom.IsDestroyed;
end;



function TKMTaskTransfer.CouldBeCancelled: Boolean;
begin
  //PackHorse is not coming from school, cannot be dismissed and so cancelled
  Result := False;
end;


procedure TKMTaskTransfer.SetFromHouse(aFromHouse: TKMHouseMarket);
begin
  fFrom := aFromHouse;
  fPointBelowFromHouse := aFromHouse.PointBelowEntrance; //save that point separately, in case fFrom will be destroyed
end;


procedure TKMTaskTransfer.SetToHouse(aToHouse: TKMHouseStore);
begin
  fTo := aToHouse;
  fPointBelowToHouse := fTo.PointBelowEntrance; //save that point separately, in case fToHouse will be destroyed
end;


//Get Transfer stage
function TKMTaskTransfer.GetTransferStage: TKMTransferStage;
var
  Phase: Integer;
begin
  Result := tsUnknown;
  Phase := fPhase - 1; //fPhase is increased at the phase end

  case Phase of
    -10..0: Result := tsToStart;
    1..3:   Result := tsAtStart;
    4:      Result := tsToDestination;
    5..7:   Result := tsAtDestination;
    8:      Result := tsToReturn;
    else    Result := tsAtReturn;
  end;
end;


function TKMTaskTransfer.Execute: TKMTaskResult;
begin
  Result := trTaskContinues;

  fPhase2 := 0;

  if WalkShouldAbandon and fUnit.Visible then
  begin
    Result := trTaskDone;
    Exit;
  end;

  //FIXME: Unit type
  with fUnit do
  case fPhase of
    0:  SetActionWalkToSpot(fFrom.PointBelowEntrance);
    1:  SetActionGoIn(uaWalk, gdGoInside, fFrom);
    2:  begin
          SetActionLockedStay(5, uaWalk); //Wait a moment inside

          //FIXME: Immediately abandon when?
          //Horse is inside house now.
          //All houses can have resources taken away by script at any moment
          if (not fFrom.ResOutputAvailable(fWareType, fWareAmount)) //No resources
          then
          begin
            fPhase := 99; //Job done
            Exit;
          end;

          //Removed ratio as it's "1:1"
          fFrom.MarketResToTrade[fWareType] := fFrom.MarketResToTrade[fWareType] - fWareAmount;
//          CarryGive;
          gHands[fFrom.Owner].Stats.WareConsumed(fWareType, fWareAmount);
          fFrom.TradeAmount := fFrom.TradeAmount - fWareAmount;

//          gHands[Owner].Transfers.Queue.TakenOffer(fTransferID);

          //TODO: Some script event might come here
//          gScriptEvents.ProcMarketTransferStart(Self, fWareType, fWareAmount, fTo);
          gSoundPlayer.Play(sfxnTrade, fPointBelowFromHouse);
        end;
    3:  begin
          if fFrom.IsDestroyed then //We have the resource, so we don't care if house is destroyed
            SetActionLockedStay(0, uaWalk)
          else
            SetActionGoIn(uaWalk, gdGoOutside, fFrom);
        end;
    4:  SetActionWalkToSpot(fTo.PointBelowEntrance);
    5:  SetActionGoIn(uaWalk, gdGoInside, fTo);
    6:  begin
          SetActionLockedStay(5, uaWalk);

          fTo.ResAddToIn(fWareType, fWareAmount);
//          CarryTake;
          gHands[fTo.Owner].Stats.WareProduced(fWareType, fWareAmount);

          //The transfer was successful, but we still have to get back
          //TODO: logistics for transfer?
//          gHands[Owner].Transfers.Queue.GaveDemand(fTransferID);
//          gHands[Owner].Transfers.Queue.AbandonTransfer(fTransferID);
          fTransferID := 0; //So that it can't be abandoned if unit dies while trying to return to From

          //TODO: Some script event might come here
//          gScriptEvents.ProcMarketTransferDone(Self, fWareType, fWareAmount, fTo);
          gSoundPlayer.Play(sfxnTrade, fPointBelowFromHouse);
        end;
    7:  begin
          if fTo.IsDestroyed then //We have the resource, so we don't care if house is destroyed
            SetActionLockedStay(0, uaWalk)
          else
            SetActionGoIn(uaWalk, gdGoOutside, fTo);
        end;
    8:  SetActionWalkToSpot(fFrom.PointBelowEntrance);
    else Result := trTaskDone;
  end;

  Inc(fPhase);
end;


function TKMTaskTransfer.ObjToString(aSeparator: String = ', '): String;
var
  FromStr, ToHStr: String;
begin
  FromStr := 'nil';
  ToHStr := 'nil';

  if fFrom <> nil then
    FromStr := fFrom.ObjToStringShort(',');

  if fTo <> nil then
    ToHStr := fTo.ObjToStringShort(',');

  Result := inherited +
            Format('%s|FromH = [%s]%s|ToH = [%s]%s|WareT = %s×%s%sPBelow FromH = %s%sPBelow ToH = %s',
                   [aSeparator,
                    FromStr, aSeparator,
                    ToHStr, aSeparator,
                    GetEnumName(TypeInfo(TKMWareType), Integer(fWareType)), IntToStr(fWareAmount), aSeparator,
                    TypeToString(fPointBelowFromHouse), aSeparator,
                    TypeToString(fPointBelowToHouse)]);
end;


procedure TKMTaskTransfer.Paint;
begin
  if SHOW_UNIT_ROUTES
    and (gMySpectator.Selected = fUnit) then
  begin
    gRenderAux.RenderWireTile(fPointBelowToHouse, icBlue);
    if fFrom <> nil then
      gRenderAux.RenderWireTile(fFrom.PointBelowEntrance, icDarkBlue);

    gRenderAux.RenderWireTile(fPointBelowToHouse, icOrange);
    if fTo <> nil then
      gRenderAux.RenderWireTile(fTo.PointBelowEntrance, icLightRed);
  end;

end;


end.
