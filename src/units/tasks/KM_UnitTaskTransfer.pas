unit KM_UnitTaskTransfer;
{$I KaM_Remake.inc}
interface
uses
  Classes, SysUtils,
  KM_CommonClasses, KM_Points, KM_Houses,
  KM_HouseMarket, KM_Units, KM_ResWares;


type
  TKMTransferStage = (tsUnknown,
                     tsAtStart,         //PackHorse is getting out from offer house
                     tsToDestination,   //PackHorse is walking to destination (unit/house)
                     tsAtDestination,   //PackHorse is operating with destination
                     tsToReturn,        //PackHorse is walking back to the offer house
                     tsAtReturn);       //PackHorse is getting in to the offer house

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
  KM_ResHouses, KM_Terrain,
  KM_Log, KM_RenderAux;


{ TTaskTransfer }
constructor TKMTaskTransfer.Create(aHorse: TKMUnit; aFrom: TKMHouseMarket; aTo: TKMHouseStore; Res: TKMWareType; Amount: Word; aID: Integer);
begin
  inherited Create(aHorse);
  fType := uttTransfer;

  Assert((aFrom <> nil) and (aTo <> nil) and (Res <> wtNone) and (Amount < MAX_WARES_ON_HORSE), 'PackHorse ' + IntToStr(fUnit.UID) + ': invalid Transfer task');

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
//  if fUnit <> nil then
//  begin
//    if fTransferID <> 0 then
//      gHands[fUnit.Owner].Transfers.Queue.AbandonTransfer(fTransferID);

//    if TKMUnitSerf(fUnit).Carry <> wtNone then
//    begin
//      gHands[fUnit.Owner].Stats.WareConsumed(TKMUnitSerf(fUnit).Carry, fWareAmount);
//      TKMUnitSerf(fUnit).CarryTake; //empty hands
//    end;
//  end;

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

  //FIXME: We should not abandon this task, but rather skip phase steps. Should the horse die if fFrom.IsDestroyed?
  if fPhase <= 4 then //onwards
      Result := Result or fTo.IsDestroyed;

  if fPhase >= 6 then //backwards
      Result := Result or fFrom.IsDestroyed;
end;



function TKMTaskTransfer.CouldBeCancelled: Boolean;
begin
  //PackHorse is not coming from school, cannot be "cancelled"
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
    -10..1: Result := tsAtStart;
    2:      Result := tsToDestination;
    3..5:   Result := tsAtDestination;
    6:      Result := tsToReturn;
    else    Result := tsAtReturn;
  end;
end;


function TKMTaskTransfer.Execute: TKMTaskResult;

//Note: Let's skip this for now, we don't want to cause more traffic jams,
// also Packhorses usually go through wild terrain
//  function NeedGoToRoad: Boolean;
//  var
//    RC, RCFrom, RCTo: Byte;
//  begin
//    //Check if we already reach destination, no need to check anymore.
//    //Also there is possibility when connected path (not diagonal) to house was cut and we have only diagonal path
//    //then its possible, that fPointBelowToHouse Connect Area will have only 1 tile, that means its WalkConnect will be 0
//    //then no need actually need to go to road
//    if (fUnit.CurrPosition = fTo.PointBelowEntrance)
//      //If we also just left From house then no need to go anywhere...
//      or (fUnit.CurrPosition = fFrom.PointBelowEntrance) then
//
//    RC := gTerrain.GetRoadConnectID(fUnit.CurrPosition);
//    RCFrom := gTerrain.GetRoadConnectID(fPointBelowFromHouse);
//    RCTo := gTerrain.GetRoadConnectID(fPointBelowToHouse);
//
//    Result := (RC = 0) or not (RC in [RCFrom, RCTo]);
//  end;

//var
//  NeedWalkBackToRoad: Boolean;
begin
  Result := trTaskContinues;

//  //Check if need walk back to road
//  //that could happen, when serf was pushd out of road or if he left offer house not onto road
//  //Used only if we walk from house to other house or construction site
//  NeedWalkBackToRoad := (((fTransferKind = dkToHouse) and ((fPhase - 1) in [4,5])) //Phase 4 could be if we just left Offer House
//                          or (((fPhase - 1) in [4,5,6]) and (fTransferKind = dkToConstruction))) //Phase 4 could be if we just left Offer House
//                        and NeedGoToRoad();

//  if not NeedWalkBackToRoad then
  fPhase2 := 0;

  if WalkShouldAbandon and fUnit.Visible then
  begin
    Result := trTaskDone;
    Exit;
  end;

//  if NeedWalkBackToRoad then
//  begin
//    case fPhase2 of
//  //No need to think if need go back to road
//  //No need 2 phases here, but let's keep old code for a while
////      0:  begin
////            fUnit.SetActionStay(1, uaWalk);
//////            fUnit.Thought := thQuest;
////          end;
//      0:  begin
//            fUnit.SetActionWalkToRoad(uaWalk, 0, tpWalkRoad,
//                              [gTerrain.GetRoadConnectID(fPointBelowToHouse), gTerrain.GetRoadConnectID(fPointBelowFromHouse)]);
//            fUnit.Thought := thNone;
//            fPhase := 5; //Start walk to Demand house again
//            fPhase2 := 10; //Some magic (yes) meaningless number...
//            Exit;
//          end;
//    end;
//  end;

  //FIXME: Unit type
  with fUnit do
  case fPhase of
    0:  begin
          SetActionLockedStay(5,uaWalk); //Wait a moment inside

          //FIXME: Immediately abandon when?
          ////Serf is inside house now.
          ////Barracks can consume the resource (by equipping) before we arrive
          ////All houses can have resources taken away by script at any moment
          //if (not fFrom.ResOutputAvailable(fWareType, fWareAmount)) //No resources
          //    or (fFrom.GetDeliveryModeForCheck(true) = dmTakeOut) //Or evacuation mode
          //then
          //begin
          //  fPhase := 99; //Job done
          //  Exit;
          //end;
          //TODO: logistics for transfer?
//          gHands[Owner].Transferies.Queue.TakenOffer(fTransferID);
        end;
    1:  begin
          if fFrom.IsDestroyed then //We have the resource, so we don't care if house is destroyed
            SetActionLockedStay(0, uaWalk)
          else
            SetActionGoIn(uaWalk, gdGoOutside, fFrom);
        end;
    2:  SetActionWalkToSpot(fTo.PointBelowEntrance);
    3:  SetActionGoIn(uaWalk, gdGoInside, fTo);
    4:  SetActionLockedStay(5, uaWalk);
    5:  begin
          fTo.ResAddToIn(fWareType, fWareAmount);
//          CarryTake;

          //The transfer was successful, but we still have to get back
          //TODO: logistics for transfer?
//          gHands[Owner].Transferies.Queue.GaveDemand(fTransferID);
//          gHands[Owner].Transferies.Queue.AbandonTransfer(fTransferID);
//          fTransferID := 0; //So that it can't be abandoned if unit dies while trying to return to From

          SetActionGoIn(uaWalk, gdGoOutside, fTo);
        end;
    6:  SetActionWalkToSpot(fFrom.PointBelowEntrance);
    7:  SetActionGoIn(uaWalk, gdGoInside, fFrom);
    8:  begin
          //TODO: Is it okay?
          SetActionLockedStay(5, uaWalk);
        end;
    else Result := trTaskDone;
  end;

  Inc(fPhase);
end;


function TKMTaskTransfer.ObjToString(aSeparator: String = ', '): String;
var
  FromStr, ToUStr, ToHStr: String;
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
