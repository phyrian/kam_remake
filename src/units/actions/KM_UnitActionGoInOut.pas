unit KM_UnitActionGoInOut;
{$I KaM_Remake.inc}
interface
uses
  Classes, KromUtils, SysUtils,
  KM_CommonClasses, KM_CommonTypes, KM_Defaults, KM_Points,
  KM_Houses, KM_Units;


type
  TKMBestExit = (beNone, beLeft, beCenter, beRight);

  {This is a [fairly :P] simple action making unit go inside/outside of house}
  TKMUnitActionGoInOut = class(TKMUnitAction)
  private
    fStep: Single;
    fHouse: TKMHouse;
    fDirection: TKMGoInDirection;
    fDoor: TKMPoint;
    fStreet: TKMPoint;
    fHasStarted: Boolean;
    fPushedUnit: TKMUnit;
    fWaitingForPush: Boolean;
    fUsedDoorway: Boolean;
    procedure IncDoorway;
    procedure DecDoorway;
    function FindBestExit(const aLoc: TKMPoint): TKMBestExit;
    function TileHasIdleUnit(X,Y: Word): TKMUnit;
    procedure WalkIn;
    procedure WalkOut;
  public
    OnWalkedOut: TEvent; //NOTE: Caller must sync these events after loading, used with caution
    OnWalkedIn: TEvent;
    constructor Create(aUnit: TKMUnit; aAction: TKMUnitActionType; aDirection: TKMGoInDirection; aHouse: TKMHouse);
    constructor Load(LoadStream: TKMemoryStream); override;
    procedure SyncLoad; override;
    destructor Destroy; override;
    function ActName: TKMUnitActionName; override;
    function CanBeInterrupted(aForced: Boolean = True): Boolean; override;
    function GetExplanation: UnicodeString; override;
    property GetHasStarted: boolean read fHasStarted;
    property GetWaitingForPush: boolean read fWaitingForPush;
    property Direction: TKMGoInDirection read fDirection;
    function GetDoorwaySlide(aCheck: TKMCheckAxis): Single;
    function Execute: TKMActionResult; override;
    procedure Save(SaveStream: TKMemoryStream); override;
  end;


implementation
uses
  KM_HandsCollection, KM_Resource, KM_Terrain, KM_UnitActionStay, KM_UnitActionWalkTo,
  KM_HouseBarracks, KM_ResHouses, KM_ResUnits, KM_CommonUtils;


{ TUnitActionGoInOut }
constructor TKMUnitActionGoInOut.Create(aUnit: TKMUnit; aAction: TKMUnitActionType; aDirection:TKMGoInDirection; aHouse:TKMHouse);
begin
  inherited Create(aUnit, aAction, True);

  //We might stuck trying to exit when house gets destroyed (1)
  //and we might be dying in destroyed house (2)
  fHouse          := aHouse.GetHousePointer;
  fDirection      := aDirection;
  fHasStarted     := False;
  fWaitingForPush := False;

  if fDirection = gdGoInside then
    fStep := 1  //go Inside (one cell up)
  else
    fStep := 0; //go Outside (one cell down)
end;


constructor TKMUnitActionGoInOut.Load(LoadStream: TKMemoryStream);
begin
  inherited;
  LoadStream.CheckMarker('UnitActionGoInOut');
  LoadStream.Read(fStep);
  LoadStream.Read(fHouse, 4);
  LoadStream.Read(fPushedUnit, 4);
  LoadStream.Read(fDirection, SizeOf(fDirection));
  LoadStream.Read(fDoor);
  LoadStream.Read(fStreet);
  LoadStream.Read(fHasStarted);
  LoadStream.Read(fWaitingForPush);
  LoadStream.Read(fUsedDoorway);
end;


procedure TKMUnitActionGoInOut.SyncLoad;
begin
  inherited;
  fHouse := gHands.GetHouseByUID(cardinal(fHouse));
  fPushedUnit := gHands.GetUnitByUID(cardinal(fPushedUnit));
end;


destructor TKMUnitActionGoInOut.Destroy;
begin
  if fUsedDoorway then
    DecDoorway;

  gHands.CleanUpHousePointer(fHouse);
  gHands.CleanUpUnitPointer(fPushedUnit);

  //A bug can occur because this action is destroyed early when a unit is told to die.
  //If we are still invisible then TTaskDie assumes we are inside and creates a new
  //GoOut action. Therefore if we are invisible we do not occupy a tile.
  if (fUnit <> nil) 
    and (fDirection = gdGoOutside)
    and fHasStarted
    and not fUnit.Visible
    and (gTerrain.Land[fUnit.NextPosition.Y,fUnit.NextPosition.X].IsUnit = fUnit) then
  begin
    gTerrain.UnitRem(fUnit.NextPosition);
    if not KMSamePoint(fDoor, KMPOINT_ZERO) then
      fUnit.PositionF := KMPointF(fDoor); //Put us back inside the house
  end;

  if (fDirection = gdGoOutside) and fUnit.Visible then
    fUnit.InHouse := nil; //We are not in any house now

  inherited;
end;


function TKMUnitActionGoInOut.ActName: TKMUnitActionName;
begin
  Result := uanGoInOut;
end;


function TKMUnitActionGoInOut.GetExplanation: UnicodeString;
begin
  Result := 'Walking in/out';
end;


procedure TKMUnitActionGoInOut.IncDoorway;
begin
  Assert(not fUsedDoorway, 'Inc doorway when already in use?');

  if fHouse <> nil then Inc(fHouse.DoorwayUse);
  fUsedDoorway := True;
end;


procedure TKMUnitActionGoInOut.DecDoorway;
begin
  Assert(fUsedDoorway, 'Dec doorway when not in use?');

  if fHouse<>nil then dec(fHouse.DoorwayUse);
  fUsedDoorway := false;
end;


//Attempt to find a tile below the door (on the street) we can walk to
//We can push idle units away. Check center first
function TKMUnitActionGoInOut.FindBestExit(const aLoc: TKMPoint): TKMBestExit;

  function ChooseBestExit(aL, aR: Boolean): TKMBestExit;
  begin
    //Choose randomly between left and right
    if (aL and aR) then
    begin
      if KaMRandom(2, 'TKMUnitActionGoInOut.FindBestExit.ChooseBestExit') = 0 then
        Result := beLeft
      else
        Result := beRight;
    end
    else
    if aL then
      Result := beLeft
    else
    if aR then
      Result := beRight
    else
      Result := beNone;
  end;

var
  U, UC, UL, UR: TKMUnit;
  L, R: Boolean;
begin
  if fUnit.CanStepTo(aLoc.X, aLoc.Y, tpWalk) then
    Result := beCenter
  else
  begin
    L := fUnit.CanStepTo(aLoc.X-1, aLoc.Y, tpWalk);
    R := fUnit.CanStepTo(aLoc.X+1, aLoc.Y, tpWalk);

    Result := ChooseBestExit(L, R);

    if Result = beNone then
    begin
      U := nil;
      UL := nil;
      UR := nil;
      //U could be nil if tile is unwalkable for some reason
      UC := TileHasIdleUnit(aLoc.X, aLoc.Y);
      if UC <> nil then
        Result := beCenter
      else
      begin
        UL := TileHasIdleUnit(aLoc.X-1, aLoc.Y);
        L := UL <> nil;
        UR := TileHasIdleUnit(aLoc.X+1, aLoc.Y);
        R := UR <> nil;
        Result := ChooseBestExit(L, R);
      end;

      case Result of
        beCenter: U := UC;
        beLeft:   U := UL;
        beRight:  U := UR;
      end;

      if U <> nil then
      begin
        fPushedUnit := U.GetUnitPointer;
        fPushedUnit.SetActionWalkPushed(gTerrain.GetOutOfTheWay(U, KMPOINT_ZERO, tpWalk));
      end;
    end;
  end;
end;


//Check that tile is walkable and there's no unit blocking it or that unit can be pushed away
function TKMUnitActionGoInOut.TileHasIdleUnit(X,Y: Word): TKMUnit;
var
  U: TKMUnit;
begin
  Result := nil;

  if gTerrain.TileInMapCoords(X,Y)
  and (gTerrain.CheckPassability(KMPoint(X,Y), fUnit.DesiredPassability))
  and (gTerrain.CanWalkDiagonaly(fUnit.CurrPosition, X, Y))
  and (gTerrain.Land[Y,X].IsUnit <> nil) then //If there's some unit we need to do a better check on him
  begin
    U := gTerrain.UnitsHitTest(X,Y); //Let's see who is standing there

    //Check that the unit is idling and not an enemy, so that we can push it away
    if (U <> nil)
    and (U.Action is TKMUnitActionStay)
    and not TKMUnitActionStay(U.Action).Locked
    and (gHands.CheckAlliance(U.Owner, fUnit.Owner) = atAlly) then
      Result := U;
  end;
end;


procedure TKMUnitActionGoInOut.WalkIn;
begin
  fUnit.Direction := dirN;  //one cell up
  fUnit.NextPosition := KMPointAbove(fUnit.CurrPosition);
  gTerrain.UnitRem(fUnit.CurrPosition); //Unit does not occupy a tile while inside

  //We are walking straight
  if fStreet.X = fDoor.X then
   IncDoorway;
end;


//Start walking out of the house. unit is no longer in the house
procedure TKMUnitActionGoInOut.WalkOut;
begin
  fUnit.Direction := KMGetDirection(fDoor, fStreet);
  fUnit.NextPosition := fStreet;
  gTerrain.UnitAdd(fUnit.NextPosition, fUnit); //Unit was not occupying tile while inside

  //Use InHouse instead of Home, since Home could be cleared via ProceedHouseClosedForWorker (f.e. when wGoingForEating = True)
  if (fUnit.UnitType = utRecruit) //Recruit
    and(fUnit.InHouse <> nil) //In some house
    and (fUnit.InHouse.HouseType = htBarracks) //Recruit is in barracks
    and (fUnit.InHouse = fHouse) then //And is the house we are walking from
    TKMHouseBarracks(fHouse).RecruitsRemove(fUnit);

  //We are walking straight
  if fStreet.X = fDoor.X then
   IncDoorway;
end;


function TKMUnitActionGoInOut.GetDoorwaySlide(aCheck: TKMCheckAxis): Single;
var Offset: Integer;
begin
  if aCheck = axX then
    Offset := gRes.Houses[fHouse.HouseType].EntranceOffsetXpx - CELL_SIZE_PX div 2
  else
    Offset := gRes.Houses[fHouse.HouseType].EntranceOffsetYpx;

  if (fHouse = nil) or not fHasStarted then
    Result := 0
  else
    Result := Mix(0, Offset/CELL_SIZE_PX, fStep);
end;


function TKMUnitActionGoInOut.Execute: TKMActionResult;
var
  Distance: Single;
  U: TKMUnit;
begin
  Result := arActContinues;

  if not fHasStarted then
  begin
    //Set Door and Street locations
    fDoor := KMPoint(fUnit.CurrPosition.X, fUnit.CurrPosition.Y - Round(fStep));
    fStreet := KMPoint(fUnit.CurrPosition.X, fUnit.CurrPosition.Y + 1 - Round(fStep));

    case fDirection of
      gdGoInside:  WalkIn;
      gdGoOutside: begin
                      case FindBestExit(fStreet) of
                        beLeft:    fStreet.X := fStreet.X - 1;
                        beCenter:  ;
                        beRight:   fStreet.X := fStreet.X + 1;
                        beNone:    Exit; //All street tiles are blocked by busy units. Do not exit the house, just wait
                      end;

                      //If we have pushed an idling unit, wait till it goes away
                      //Wait until our push request is dealt with before we move out
                      if (fPushedUnit <> nil) then
                      begin
                        fWaitingForPush := True;
                        fHasStarted := True;
                        Exit;
                      end
                      else
                        WalkOut; //Otherwise we can walk out now
                    end;
    end;

    fHasStarted := True;
  end;


  if fWaitingForPush then
  begin
    U := gTerrain.Land[fStreet.Y,fStreet.X].IsUnit;
    if (U = nil) then //Unit has walked away
    begin
      fWaitingForPush := False;
      gHands.CleanUpUnitPointer(fPushedUnit);
      WalkOut;
    end
    else
    begin //There's still some unit - we can't go outside
      if (U <> fPushedUnit) //The unit has switched places with another one, so we must start again
        or not (U.Action is TKMUnitActionWalkTo) //Unit was interupted (no longer pushed), so start again
        or not TKMUnitActionWalkTo(U.Action).WasPushed then
      begin
        fHasStarted := False;
        fWaitingForPush := False;
        gHands.CleanUpUnitPointer(fPushedUnit);
      end;
      Exit;
    end;
  end;

  //IsExchanging can be updated while we have completed less than 20% of the move. If it is changed after that
  //the unit makes a noticable "jump". This needs to be updated after starting because we don't know about an
  //exchanging unit until they have also started walking (otherwise only 1 of the units will have IsExchanging = true)
  if (
      ((fDirection = gdGoOutside) and (fStep < 0.2)) or
      ((fDirection = gdGoInside) and (fStep > 0.8))
      )
    and (fStreet.X = fDoor.X) //We are walking straight
    and (fHouse <> nil) then
    fUnit.IsExchanging := (fHouse.DoorwayUse > 1);

  Assert((fHouse = nil) or KMSamePoint(fDoor, fHouse.Entrance)); //Must always go in/out the entrance of the house
  Distance := gRes.Units[fUnit.UnitType].Speed;

  //Actual speed is slower if we are moving diagonally, due to the fact we are moving in X and Y
  if (fStreet.X - fDoor.X <> 0) then
    Distance := Distance / 1.41; {sqrt (2) = 1.41421 }

  fStep := fStep - Distance * ShortInt(fDirection);
  fUnit.PositionF := KMLerp(fDoor, fStreet, fStep);
  fUnit.Visible := (fHouse = nil) or (fHouse.IsDestroyed) or (fStep > 0); //Make unit invisible when it's inside of House

  if (fStep <= 0) or (fStep >= 1) then
  begin
    Result := arActDone;
    fUnit.IsExchanging := False;
    if fUsedDoorway then DecDoorway;
    if fDirection = gdGoInside then
    begin
      fUnit.PositionF := KMPointF(fDoor);
      if (fUnit.Home <> nil)
      and (fUnit.Home = fHouse)
      and (fUnit.Home.HouseType = htBarracks) //Unit home is barracks
      and not fUnit.Home.IsDestroyed then //And is the house we are walking into and it's not destroyed
        TKMHouseBarracks(fUnit.Home).RecruitsAdd(fUnit); //Add the recruit once it is inside, otherwise it can be equipped while still walking in!
      //Set us as inside even if the house is destroyed. In that case UpdateVisibility will sort things out.

      //When any woodcutter returns home - add an Axe
      //(this might happen when he walks home or when mining is done)
      if (fUnit.UnitType = utWoodcutter)
      and (fUnit.Home <> nil)
      and (fUnit.Home.HouseType = htWoodcutters)
      and (fUnit.Home = fHouse) then //And is the house we are walking from
        fHouse.CurrentAction.SubActionAdd([haFlagpole]);

      if Assigned(OnWalkedIn) then
        OnWalkedIn;

      if fHouse <> nil then
        fUnit.InHouse := fHouse;
    end
    else
    begin
      fUnit.PositionF := KMPointF(fStreet);
      fUnit.InHouse := nil; //We are not in a house any longer
      if Assigned(OnWalkedOut) then
        OnWalkedOut;
    end;
  end
  else
    Inc(fUnit.AnimStep);
end;


procedure TKMUnitActionGoInOut.Save(SaveStream: TKMemoryStream);
begin
  inherited;
  SaveStream.PlaceMarker('UnitActionGoInOut');
  SaveStream.Write(fStep);
  if fHouse <> nil then
    SaveStream.Write(fHouse.UID) //Store ID, then substitute it with reference on SyncLoad
  else
    SaveStream.Write(Integer(0));
  if fPushedUnit <> nil then
    SaveStream.Write(fPushedUnit.UID) //Store ID, then substitute it with reference on SyncLoad
  else
    SaveStream.Write(Integer(0));
  SaveStream.Write(fDirection, SizeOf(fDirection));
  SaveStream.Write(fDoor);
  SaveStream.Write(fStreet);
  SaveStream.Write(fHasStarted);
  SaveStream.Write(fWaitingForPush);
  SaveStream.Write(fUsedDoorway);
end;


function TKMUnitActionGoInOut.CanBeInterrupted(aForced: Boolean = True): Boolean;
begin
  Result := not Locked; //Never interupt leaving barracks
end;


end.

