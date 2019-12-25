unit KM_GameInputProcess_Single;
{$I KaM_Remake.inc}
interface
uses
  KM_CommonClasses, KM_GameInputProcess;


type
  TKMGameInputProcess_Single = class(TKMGameInputProcess)
  protected
    procedure TakeCommand(const aCommand: TKMGameInputCommand); override;
    procedure SaveExtra(SaveStream: TKMemoryStream); override;
    procedure LoadExtra(LoadStream: TKMemoryStream); override;
  public
    procedure ReplayTimer(aTick: Cardinal); override;
    procedure RunningTimer(aTick: Cardinal); override;
  end;


implementation
uses
  Math, KM_Game, KM_Defaults, KM_CommonUtils;


procedure TKMGameInputProcess_Single.TakeCommand(const aCommand: TKMGameInputCommand);
begin
  if gGame.IsReplay then Exit;

  StoreCommand(aCommand); //Store the command for the replay (store it first in case Exec crashes and we want to debug it)
  ExecCommand(aCommand);  //Execute the command now
end;


procedure TKMGameInputProcess_Single.ReplayTimer(aTick: Cardinal);
var
  MyRand: Cardinal;
begin
  //This is to match up with multiplayer random check generation, so multiplayer replays can be replayed in singleplayer mode
  if aTick > 0 then //On 0 tick we did not call for RunningTimer during the game, so no need to call it here while watching replay
    KaMRandom(MaxInt, 'TKMGameInputProcess_Single.ReplayTimer');
  //There are still more commands left
  if fCursor <= Count then
  begin
    while (aTick > fQueue[fCursor].Tick) and (fQueue[fCursor].Command.CommandType <> gicNone) and (fCursor < Count) do
      Inc(fCursor);

    while (fCursor <= Count) and (aTick = fQueue[fCursor].Tick) do //Could be several commands in one Tick
    begin
      //Call to KaMRandom, just like in StoreCommand
      //We did not generate random checks for those commands
      if SKIP_RNG_CHECKS_FOR_SOME_GIC and (fQueue[fCursor].Command.CommandType in SkipRandomChecksFor) then
        MyRand := 0
      else
        MyRand := Cardinal(KaMRandom(MaxInt, 'TKMGameInputProcess_Single.ReplayTimer 2'));
      ExecCommand(fQueue[fCursor].Command); //Should always be called to maintain randoms flow
      //CRC check after the command
      if (fQueue[fCursor].Rand <> MyRand)
        and not gGame.IgnoreConsistencyCheckErrors
        and CRASH_ON_REPLAY then
      begin
        Inc(fCursor); //Must be done before exiting in case user decides to continue the replay
        gGame.ReplayInconsistancy(fQueue[fCursor-1], MyRand);
        Exit; //ReplayInconsistancy sometimes calls GIP.Free, so exit immidiately
      end;
      Inc(fCursor);
    end;
  end;
end;


procedure TKMGameInputProcess_Single.RunningTimer(aTick: Cardinal);
begin
  inherited;

  KaMRandom(MaxInt, 'TKMGameInputProcess_Single.RunningTimer'); //This is to match up with multiplayer CRC generation, so multiplayer replays can be replayed in singleplayer mode
end;


procedure TKMGameInputProcess_Single.SaveExtra(SaveStream: TKMemoryStream);
begin
  SaveStream.Write(gGame.LastReplayTick);
end;


procedure TKMGameInputProcess_Single.LoadExtra(LoadStream: TKMemoryStream);
var
  LastReplayTick: Cardinal;
begin
  LoadStream.Read(LastReplayTick);
  gGame.LastReplayTick := LastReplayTick;
end;


end.

