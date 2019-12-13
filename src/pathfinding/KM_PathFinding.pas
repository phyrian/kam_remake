unit KM_PathFinding;
{$I KaM_Remake.inc}
interface
uses
  SysUtils, Math, KromUtils,
  KM_CommonClasses, KM_Defaults, KM_Houses, KM_Terrain, KM_Points;


const
  PATH_CACHE_MAX = 12; //How many paths to cache
  PATH_CACHE_INIT_WEIGHT = 5; //New path weight
  PATH_CACHE_NODES_MIN_CNT = 20; //Min number of noder to put route in cache

type
  TKMPathDestination = (
    pdLocation, //Walk to location
    pdPassability, //Walk to desired passability
    pdHouse //Approach house from any side (workers and warriors)
    );

  //This is a helper class for TTerrain
  //Here should be pathfinding and all associated stuff
  //I think we should refactor this unit and move some TTerrain methods here
  TPathFinding = class
  private
    fCache: array [0 .. PATH_CACHE_MAX - 1] of record
      Weight: Word;
      Pass: TKMTerrainPassabilitySet;
      Route: TKMPointList;
    end;
  protected
    fPass: TKMTerrainPassabilitySet;
    fTargetWalkConnect: TKMWalkConnect;
    fTargetNetwork: Byte;
    fDistance: Single;
    fIsInteractionAvoid: Boolean;
    fTargetHouse: TKMHouse;
    procedure AddToCache(NodeList: TKMPointList);
    function TryRouteFromCache(NodeList: TKMPointList): Boolean;
  protected
    fLocA: TKMPoint;
    fLocB: TKMPoint;
    fDestination: TKMPathDestination;
    function CanWalkTo(const aFrom: TKMPoint; bX, bY: SmallInt): Boolean; virtual;
    function DestinationReached(aX, aY: Word): Boolean; virtual;
    function IsWalkableTile(aX, aY: Word): Boolean; virtual;
    function MovementCost(aFromX, aFromY, aToX, aToY: Word): Word; virtual;
    function EstimateToFinish(aX, aY: Word): Word; virtual;
    function MakeRoute: Boolean; virtual; abstract;
    procedure ReturnRoute(NodeList: TKMPointList); virtual; abstract;
  public
    constructor Create;
    destructor Destroy; override;

    function Route_Make(const aLocA, aLocB: TKMPoint; aPass: TKMTerrainPassabilitySet; aDistance: Single;
                        aTargetHouse: TKMHouse; NodeList: TKMPointList; aAvoidLocked: Boolean = False): Boolean;
    function Route_MakeAvoid(const aLocA, aLocB: TKMPoint; aPass: TKMTerrainPassabilitySet; aDistance: Single; aTargetHouse: TKMHouse; NodeList: TKMPointList): Boolean;
    function Route_ReturnToWalkable(const aLocA, aLocB: TKMPoint; aTargetWalkConnect: TKMWalkConnect; aTargetNetwork: Byte;
                                    aPass: TKMTerrainPassabilitySet; NodeList: TKMPointList): Boolean;

    procedure Save(SaveStream: TKMemoryStream); virtual;
    procedure Load(LoadStream: TKMemoryStream); virtual;
    procedure UpdateState;
  end;


implementation
uses
  KM_Units;


{ TPathFinding }
constructor TPathFinding.Create;
var
  I: Integer;
begin
  inherited;

  if CACHE_PATHFINDING then
  for I := 0 to PATH_CACHE_MAX - 1 do
    fCache[I].Route := TKMPointList.Create;
end;


destructor TPathFinding.Destroy;
var
  I: Integer;
begin
  if CACHE_PATHFINDING then
  for I := 0 to PATH_CACHE_MAX - 1 do
    FreeAndNil(fCache[I].Route);

  inherited;
end;


//Find a route from A to B which meets aPass Passability
//Results should be written as NodeCount of waypoint nodes to Nodes
function TPathFinding.Route_Make(const aLocA, aLocB: TKMPoint; aPass: TKMTerrainPassabilitySet; aDistance: Single;
                                 aTargetHouse: TKMHouse; NodeList: TKMPointList; aAvoidLocked: Boolean = False): Boolean;
begin
  Result := False;

  fLocA := aLocA;
  fLocB := aLocB;
  fPass := aPass;
  fTargetNetwork := 0;
  fTargetWalkConnect := wcWalk;
  fDistance := aDistance;
  fIsInteractionAvoid := aAvoidLocked;
  fTargetHouse := aTargetHouse;
  if fTargetHouse = nil then
    fDestination := pdLocation
  else
    fDestination := pdHouse;

  //Try to find similar route in cache and reuse it
  if CACHE_PATHFINDING and TryRouteFromCache(NodeList) then
    Result := True
  else
  if MakeRoute then
  begin
    ReturnRoute(NodeList);
    Result := True;
  end else
    NodeList.Clear;
end;


//We are using Interaction Avoid mode (go around busy units)
function TPathFinding.Route_MakeAvoid(const aLocA, aLocB: TKMPoint; aPass: TKMTerrainPassabilitySet; aDistance: Single; aTargetHouse: TKMHouse; NodeList: TKMPointList): Boolean;
begin
  Result := False;

  fLocA := aLocA;
  fLocB := aLocB;
  fPass := aPass;
  fTargetNetwork := 0;
  fTargetWalkConnect := wcWalk;
  fDistance := aDistance;
  fIsInteractionAvoid := True;
  fTargetHouse := aTargetHouse;
  if fTargetHouse = nil then
    fDestination := pdLocation
  else
    fDestination := pdHouse;

  if MakeRoute then
  begin
    ReturnRoute(NodeList);
    Result := True;
  end;
end;


//Even though we are only going to a road network it is useful to know where our target is so we start off in the right direction (makes algorithm faster/work over long distances)
function TPathFinding.Route_ReturnToWalkable(const aLocA, aLocB: TKMPoint; aTargetWalkConnect: TKMWalkConnect; aTargetNetwork: Byte; aPass: TKMTerrainPassabilitySet; NodeList: TKMPointList): Boolean;
begin
  Result := False;

  fLocA := aLocA;
  fLocB := aLocB;
  fPass := aPass; //Should be unused here
  fTargetNetwork := aTargetNetwork;
  fTargetWalkConnect := aTargetWalkConnect;
  fDistance := 0;
  fIsInteractionAvoid := False;
  fTargetHouse := nil;
  fDestination := pdPassability;

  if MakeRoute then
  begin
    ReturnRoute(NodeList);
    Result := True;
  end else
    NodeList.Clear;
end;


function TPathFinding.CanWalkTo(const aFrom: TKMPoint; bX, bY: SmallInt): Boolean;
begin
  Result := gTerrain.CanWalkDiagonaly(aFrom, bX, bY);
end;


function TPathFinding.IsWalkableTile(aX, aY: Word): Boolean;
begin
  //If cell meets Passability then estimate it
  Result := (fPass * gTerrain.Land[aY,aX].Passability) <> [];
end;


//How much it costs to move From -> To
function TPathFinding.MovementCost(aFromX, aFromY, aToX, aToY: Word): Word;
var DX, DY: Word; U: TKMUnit;
begin
  DX := Abs(aFromX - aToX);
  DY := Abs(aFromY - aToY);
  if DX > DY then
    Result := DX * 10 + DY * 4
  else
    Result := DY * 10 + DX * 4;

  //Do not add extra cost if the tile is the target, as it can cause a longer route to be chosen
  if (aToX <> fLocB.X) or (aToY <> fLocB.Y) then
  begin
    U := gTerrain.Land[aToY,aToX].IsUnit;
    //Always avoid congested areas on roads
    if DO_WEIGHT_ROUTES and (U <> nil) and ((tpWalkRoad in fPass) or U.PathfindingShouldAvoid) then
      Inc(Result, 15); //Unit = 1.5 extra tiles
    if fIsInteractionAvoid and gTerrain.TileIsLocked(KMPoint(aToX,aToY)) then
      Inc(Result, 200); //In interaction avoid mode, working unit (or warrior attacking house) = 20 tiles
  end;
end;


function TPathFinding.EstimateToFinish(aX, aY: Word): Word;
var
  DX, DY: Word;
begin
  //Use Estim even if destination is Passability, as it will make it faster.
  //Target should be in the right direction even though it's not our destination.
  DX := Abs(fLocB.X - aX);
  DY := Abs(fLocB.Y - aY);
  if DX > DY then
    Result := DX * 10 + DY * 4
  else
    Result := DY * 10 + DX * 4;
end;


function TPathFinding.DestinationReached(aX, aY: Word): Boolean;
begin
  case fDestination of
    pdLocation:    Result := KMLengthDiag(aX, aY, fLocB) <= fDistance;
    pdPassability: Result := gTerrain.GetConnectID(fTargetWalkConnect, KMPoint(aX, aY)) = fTargetNetwork;
    pdHouse:       Result := fTargetHouse.InReach(KMPoint(aX, aY), fDistance);
    else           Result := True;
  end;
end;


//Cache the route incase it is needed soon
procedure TPathFinding.AddToCache(NodeList: TKMPointList);
var
  I: Integer;
  Best: Integer;
begin
  //Find cached route with least weight and replace it
  Best := 0;
  for I := 1 to PATH_CACHE_MAX - 1 do
  if fCache[I].Weight < fCache[Best].Weight then
    Best := I;

  fCache[Best].Weight := PATH_CACHE_INIT_WEIGHT;
  fCache[Best].Pass := fPass;
  fCache[Best].Route.Copy(NodeList);
end;


function TPathFinding.TryRouteFromCache(NodeList: TKMPointList): Boolean;
const
  MIN_POINTS_TO_CHECK_START = 10;

var
  I,K: Integer;
  BestStart, BestEnd: Integer;
  NewL, BestL: Single;
  P: TKMPoint;
  IsWalkable: Boolean;
begin
  //Makes compiler happy
  Result := False;

  for I := 0 to PATH_CACHE_MAX - 1 do
  begin
    BestStart := -1;
    BestEnd := -1;
    if (fCache[I].Route.Count > 0)
      and (fCache[I].Pass = fPass) then
    begin
      //Check if route goes through out position
      //We could check almost all points
      for K := 0 to Max(MIN_POINTS_TO_CHECK_START,
                        fCache[I].Route.Count - 1 - PATH_CACHE_NODES_MIN_CNT) do
      begin
        //Restrict cache to go through our starting point,
        //otherwise some bad-looking behaviour possible
        //F.e. units going in a row could make side step occasionaly,
        //cause 1st one change route
        if KMLengthDiag(fLocA, fCache[I].Route[K]) = 0 then
        begin
          BestStart := K;
          Break;
        end;
      end;

      if BestStart = -1 then Continue;

      //Check if route ends within reach
      BestL := MaxSingle;
      for K := fCache[I].Route.Count - 1 downto BestStart + 1 do
      begin
        NewL := KMLengthDiag(fLocB, fCache[I].Route[K]);
        if (NewL <= 1)
          or ((NewL < 2)
            and gTerrain.CanWalkDiagonaly(fLocB, fCache[I].Route[K].X, fCache[I].Route[K].Y)) then
        begin
          BestEnd := K;
          BestL := NewL;
          if NewL = 0 then //Path goes through our Destination
            Break;
        end;
      end;

      if BestL >= 2 then Continue;

      //Check if cached path is still walkable
      IsWalkable := True;
      for K := BestStart to BestEnd do
      begin
        P := fCache[I].Route[K];
        if not IsWalkableTile(P.X, P.Y) then
        begin
          IsWalkable := False;
          Break;
        end;
      end;

      //If not walkable anymore, then mark it as unused
      //and continue
      if not IsWalkable then
      begin
        fCache[I].Weight := 0;
        fCache[I].Pass := [];
        Continue;
      end;

      //Assemble the route
      NodeList.Clear;
      //No need to add fLocA, since its equal to BestStart point from Cached Route
      for K := BestStart to BestEnd do
        NodeList.Add(fCache[I].Route[K]);

      if fLocB <> fCache[I].Route[BestEnd] then //No need to duplicate fLocB
        NodeList.Add(fLocB);

      //Mark the cached route as more useful
      Inc(fCache[I].Weight);

      Result := True;
      Exit;
    end;
  end;
end;


procedure TPathFinding.Save(SaveStream: TKMemoryStream);
var
  I: Integer;
begin
  SaveStream.PlaceMarker('PathFinding');

  if CACHE_PATHFINDING then
  for I := 0 to PATH_CACHE_MAX - 1 do
  begin
    SaveStream.Write(fCache[I].Weight);
    SaveStream.Write(fCache[I].Pass, SizeOf(fCache[I].Pass));
    fCache[I].Route.SaveToStream(SaveStream);
  end;
end;


procedure TPathFinding.Load(LoadStream: TKMemoryStream);
var
  I: Integer;
begin
  LoadStream.CheckMarker('PathFinding');

  if CACHE_PATHFINDING then
  for I := 0 to PATH_CACHE_MAX - 1 do
  begin
    LoadStream.Read(fCache[I].Weight);
    LoadStream.Read(fCache[I].Pass, SizeOf(fCache[I].Pass));
    fCache[I].Route.LoadFromStream(LoadStream);
  end;
end;


procedure TPathFinding.UpdateState;
var
  I: Integer;
begin
  if CACHE_PATHFINDING then
  for I := 0 to PATH_CACHE_MAX - 1 do
    fCache[I].Weight := Max(fCache[I].Weight - 1, 0);
end;


end.
