unit KM_Main;
{$I KaM_Remake.inc}
interface
uses
  Classes, Controls, Forms, Math, SysUtils, StrUtils, Dialogs,
  {$IFDEF MSWindows} Windows, MMSystem, {$ENDIF}
  KromUtils, KM_FormLoading, KM_FormMain, KM_Settings, KM_Resolutions{$IFDEF USE_MAD_EXCEPT}, KM_Exceptions{$ENDIF};

type
  TKMMain = class
  private
    fFormMain: TFormMain;
    fFormLoading: TFormLoading;

    fOldTimeFPS, fOldFrameTimes, fFrameCount: Cardinal;
    fMutex: THandle;

    fMainSettings: TMainSettings;
    fResolutions: TKMResolutions;

    procedure DoRestore(Sender: TObject);
    procedure DoDeactivate(Sender: TObject);
    procedure DoIdle(Sender: TObject; var Done: Boolean);
  public
    constructor Create;
    destructor Destroy; override;

    procedure Start;
    procedure CloseQuery(var CanClose: Boolean);
    procedure Stop(Sender: TObject);

    procedure Resize(X,Y: Integer);
    procedure Render;
    procedure ShowAbout;

    procedure ApplyCursorRestriction;
    function GetScreenBounds(out Bounds: TRect):Boolean;
    function IsFormActive: Boolean;
    function ClientRect: TRect;
    function ClientToScreen(aPoint: TPoint): TPoint;
    procedure ReinitRender(aReturnToOptions: Boolean);

    function LockMutex:Boolean;
    procedure UnlockMutex;

    procedure StatusBarText(aPanelIndex: Integer; const aText: string); overload;

    property Resolutions: TKMResolutions read fResolutions;
    property Settings: TMainSettings read fMainSettings;
  end;


var
  fMain: TKMMain;


implementation
uses KM_Defaults, KM_GameApp, KM_Utils, KM_Log;

const
  //Random GUID generated in Delphi by Ctrl+G
  KAM_MUTEX = '07BB7CC6-33F2-44ED-AD04-1E255E0EDF0D';

{ TKMRemake }
constructor TKMMain.Create;
begin
  inherited;
  //Create exception handler as soon as possible in case it crashes early on
  {$IFDEF USE_MAD_EXCEPT}fExceptions := TKMExceptions.Create;{$ENDIF}

  //Form created first will be on taskbar
  Application.CreateForm(TFormMain, fFormMain);
  Application.CreateForm(TFormLoading, fFormLoading);
end;


destructor TKMMain.Destroy;
begin
  {$IFDEF USE_MAD_EXCEPT}fExceptions.Free;{$ENDIF}
  inherited;
end;


procedure TKMMain.Start;
begin
  SetKaMSeed(4); //Used for gameplay events so the order is important
  Randomize; //Random is only used for cases where order does not matter, e.g. shuffle tracks

  fFormLoading.Label5.Caption := GAME_VERSION;
  fFormLoading.Show; //This is our splash screen
  fFormLoading.Refresh;

  {$IFDEF MSWindows}
  TimeBeginPeriod(1); //initialize timer precision
  {$ENDIF}
  ExeDir := ExtractFilePath(Application.ExeName);

  CreateDir(ExeDir + 'Logs\');
  fLog := TKMLog.Create(ExeDir + 'Logs\KaM_' + FormatDateTime('yyyy-mm-dd_hh-nn-ss-zzz', Now) + '.log'); //First thing - create a log
  fLog.DeleteOldLogs;

  fResolutions := TKMResolutions.Create;

  //Only after we read settings (fullscreen property and resolutions)
  //we can decide whenever we want to create Game fullscreen or not (OpenGL init depends on that)
  fMainSettings := TMainSettings.Create;
  //We need to verify INI values, as they can be from another display
  if not fResolutions.IsValid(fMainSettings.Resolution) then
  begin
    fMainSettings.Resolution := fResolutions.FindCorrect(fMainSettings.Resolution);
    if not fResolutions.IsValid(fMainSettings.Resolution) then
      fMainSettings.FullScreen := False;
  end;

  fFormMain.Caption := 'KaM Remake - ' + GAME_VERSION;
  //Will make the form slightly higher, so do it before ReinitRender so it is reset
  fFormMain.ToggleControlsVisibility(SHOW_DEBUG_CONTROLS);

  ReinitRender(False);

  Application.OnIdle := DoIdle;
  Application.OnDeactivate := DoDeactivate;
  Application.OnRestore := DoRestore; //OnActivate seems to happen at the wrong times, OnRestore happens when alt-tabbing back in full screen mode

  fFormLoading.Hide;
end;


procedure TKMMain.StatusBarText(aPanelIndex: Integer; const aText: string);
begin
  fFormMain.StatusBar1.Panels[aPanelIndex].Text := aText;
end;


procedure TKMMain.CloseQuery(var CanClose: Boolean);
begin
  //MessageDlg works better than Application.MessageBox or others, it stays on top and
  //pauses here until the user clicks ok.
  CanClose := (fGameApp = nil) or fGameApp.CanClose;

  if not CanClose then
  begin
    //todo: Pause the game
    //if fGame.Running then fGame.Pause

    //Ask the Player
    CanClose :=
      //(MessageDlg('Any unsaved changes will be lost. Exit?', mtWarning, [mbYes, mbNo], 0) = mrYes);
      MessageBox(fFormMain.Handle, PChar('Any unsaved changes will be lost. Exit?'),
                         PChar('Warning'),
                         MB_YESNO or MB_ICONWARNING or MB_SETFOREGROUND
                         or MB_TASKMODAL) = IDYES;//}

    //todo: Resume the game
    if not CanClose then
      //if fGame.WasRunning then fGame.Resume
  end;
end;


procedure TKMMain.Stop(Sender: TObject);
begin
  //Reset the resolution
  if fResolutions<>nil then FreeThenNil(fResolutions);
  if fMainSettings<>nil then FreeThenNil(fMainSettings);
  FreeThenNil(fGameApp);
  if fLog<>nil then FreeThenNil(fLog);
  {$IFDEF MSWindows}
  TimeEndPeriod(1);
  ClipCursor(nil); //Release the cursor restriction
  {$ENDIF}

  //We could be asked to close from MainForm or from other place
  //In first case Form will take care about closing itself
  if Sender <> fFormMain then
    fFormMain.Close;
end;


//Apply the cursor restriction when alt-tabbing back
procedure TKMMain.DoRestore(Sender: TObject);
begin
  if Application.Active and (fMainSettings <> nil) then
    ApplyCursorRestriction; //Cursor restriction is lost when alt-tabbing out, so we need to apply it again
end;


procedure TKMMain.DoDeactivate(Sender: TObject);
begin
  //Occurs during Toggle to fullscreen, should be ignored
  if Application.Active then Exit;

  //Prevent the game window from being in the way by minimizing when alt-tabbing
  if (fMainSettings <> nil) and fMainSettings.FullScreen then
  begin
    ClipCursor(nil); //Remove all cursor clipping just in case Windows doesn't automatically
    Application.Minimize;
  end;
end;


procedure TKMMain.DoIdle(Sender: TObject; var Done: Boolean);
var
  FrameTime: Cardinal;
begin
  //if not Form1.Active then exit;

  //Counting FPS
  begin
    FrameTime  := TimeGet - fOldTimeFPS;
    fOldTimeFPS := TimeGet;

    if CAP_MAX_FPS and (FPS_LAG <> 1) and (FrameTime < FPS_LAG) then
    begin
      Sleep(FPS_LAG - FrameTime);
      FrameTime := FPS_LAG;
    end;

    inc(fOldFrameTimes, FrameTime);
    inc(fFrameCount);
    if fOldFrameTimes >= FPS_INTERVAL then
    begin
      StatusBarText(3, Format('%.1f fps', [1000 / (fOldFrameTimes / fFrameCount)]) +
                       IfThen(CAP_MAX_FPS, ' (' + inttostr(FPS_LAG) + ')'));
      fOldFrameTimes := 0;
      fFrameCount := 0;
    end;
  end;
  //FPS calculation complete

  if fGameApp <> nil then
  begin
    fGameApp.UpdateStateIdle(FrameTime);
    fGameApp.Render;
  end;

  Done := False; //Repeats OnIdle asap without performing Form-specific idle code
end;


procedure TKMMain.ReinitRender(aReturnToOptions: Boolean);
begin
  if fMainSettings.FullScreen then
    if fResolutions.IsValid(fMainSettings.Resolution) then
      fResolutions.SetResolution(fMainSettings.Resolution)
    else
      fMainSettings.FullScreen := False
  else
    fResolutions.Restore;

  fFormLoading.Position := poScreenCenter;
  fFormMain.ToggleFullscreen(fMainSettings.FullScreen);

  //It's required to re-init whole OpenGL related things when RC gets toggled fullscreen
  FreeThenNil(fGameApp); //Saves all settings into ini file in midst
  fGameApp := TKMGameApp.Create(
                                fFormMain.Panel5.Handle,
                                fFormMain.Panel5.Width,
                                fFormMain.Panel5.Height,
                                fMainSettings.VSync,
                                fFormLoading.LoadingStep,
                                fFormLoading.LoadingText,
                                StatusBarText);
  fGameApp.AfterConstruction(aReturnToOptions);

  fLog.AppendLog('ToggleFullscreen');
  fLog.AppendLog('Form Width/Height: '+inttostr(fFormMain.Width)+':'+inttostr(fFormMain.Height));
  fLog.AppendLog('Panel Width/Height: '+inttostr(fFormMain.Panel5.Width)+':'+inttostr(fFormMain.Panel5.Height));

  //Hide'n'show will make form go ontop of taskbar
  fFormMain.Hide;
  fFormMain.Show;

  Resize(fFormMain.Panel5.Width, fFormMain.Panel5.Height); //Force everything to resize
  ApplyCursorRestriction;
end;


function TKMMain.LockMutex: Boolean;
begin
  Result := True;
  if not BLOCK_DUPLICATE_APP then Exit;
  fMutex := CreateMutex(nil, True, PChar(KAM_MUTEX));
  if fMutex = 0 then
    RaiseLastOSError;
  Result := (GetLastError <> ERROR_ALREADY_EXISTS);
  if not Result then UnlockMutex; //Close our own handle on the mutex because someone else already made the mutex
end;


procedure TKMMain.UnlockMutex;
begin
  if not BLOCK_DUPLICATE_APP then Exit;
  if fMutex = 0 then Exit; //Didn't have a mutex lock
  CloseHandle(fMutex);
  fMutex := 0;
end;


function TKMMain.ClientRect: TRect;
begin
  Result := fFormMain.Panel5.ClientRect;
  Result.TopLeft := ClientToScreen(Result.TopLeft);
  Result.BottomRight := ClientToScreen(Result.BottomRight);
end;


function TKMMain.ClientToScreen(aPoint: TPoint): TPoint;
begin
  Result := fFormMain.Panel5.ClientToScreen(aPoint);
end;


//Can be invalid very breifly if you change resolutions (this is possible in Windowed mode)
function TKMMain.GetScreenBounds(out Bounds: TRect): Boolean;
var I: Integer;
begin
  Result := False;
  Bounds := Classes.Rect(-1,-1,-1,-1);
  fFormMain.Monitor; //This forces Delphi to reload Screen.Monitors (only if necessary) and so fixes crashes when using multiple monitors
  //Maximized is a special case, it can only be on one monitor. This is required because when maximized form.left = -9 (on Windows 7 anyway)
  if fFormMain.WindowState = wsMaximized then
  begin
    for I:=0 to Screen.MonitorCount-1 do
      //Find the monitor with the left closest to the left of the form
      if (I = 0) or
         ((abs(fFormMain.Left - Screen.Monitors[I].Left) <= abs(fFormMain.Left - Bounds.Left)) and
          (abs(fFormMain.Top  - Screen.Monitors[I].Top ) <= abs(fFormMain.Top  - Bounds.Top))) then
      begin
        Result := True;
        Bounds.Left  := Screen.Monitors[I].Left;
        Bounds.Right := Screen.Monitors[I].Width+Screen.Monitors[I].Left;
        Bounds.Top   := Screen.Monitors[I].Top;
        Bounds.Bottom:= Screen.Monitors[I].Height+Screen.Monitors[I].Top;
      end;
  end
  else
    for I:=0 to Screen.MonitorCount-1 do
      //See if our form is within the boundaries of this monitor (I.e. when it is not outside the boundaries)
      if not ((fFormMain.Left               >= Screen.Monitors[I].Width + Screen.Monitors[I].Left) or
              (fFormMain.Width + fFormMain.Left <= Screen.Monitors[I].Left) or
              (fFormMain.Top                >= Screen.Monitors[I].Height + Screen.Monitors[I].Top) or
              (fFormMain.Height + fFormMain.Top <= Screen.Monitors[I].Top)) then
      begin
        if not Result then
        begin
          //First time we have to initialise the result
          Result := True;
          Bounds.Left  := Screen.Monitors[I].Left;
          Bounds.Right := Screen.Monitors[I].Width+Screen.Monitors[I].Left;
          Bounds.Top   := Screen.Monitors[I].Top;
          Bounds.Bottom:= Screen.Monitors[I].Height+Screen.Monitors[I].Top;
        end
        else
        begin
          //After the first time we compare it with the previous result and take the largest possible area
          Bounds.Left  := Math.Min(Bounds.Left,  Screen.Monitors[I].Left);
          Bounds.Right := Math.Max(Bounds.Right, Screen.Monitors[I].Width+Screen.Monitors[I].Left);
          Bounds.Top   := Math.Min(Bounds.Top,   Screen.Monitors[I].Top);
          Bounds.Bottom:= Math.Max(Bounds.Bottom,Screen.Monitors[I].Height+Screen.Monitors[I].Top);
        end;
      end;
end;


function TKMMain.IsFormActive: Boolean;
begin
  Result := fFormMain.Active;
end;


procedure TKMMain.Render;
begin
  if fGameApp <> nil then
    fGameApp.Render;
end;


procedure TKMMain.Resize(X, Y: Integer);
begin
  //Don't log this by default, resizing can happen lots of times per second (~30ms between log entries)
  //when dragging the screen edge and that means lots of file open-write-close which is slow.
  //if fLog <> nil then
  //  fLog.AppendLog('FormResize X/Y: '+inttostr(X)+':'+inttostr(Y));

  if fGameApp <> nil then
    fGameApp.Resize(X, Y);
end;


procedure TKMMain.ShowAbout;
begin
  fFormLoading.Bar1.Position := 0;
  fFormLoading.Label1.Caption := '';
  fFormLoading.Show;
end;


//Restrict cursor movement in fullscreen mode
//For multiple monitors, it's very annoying if you play a fullscreen game and your cursor slides
//onto second monitor instead of stopping at the edge as expected.
procedure TKMMain.ApplyCursorRestriction;
var Rect: TRect;
begin
  //This restriction is removed when alt-tabbing out, and added again when alt-tabbing back
  {$IFDEF MSWindows}
  if fMainSettings.FullScreen then
  begin
    Rect := fFormMain.BoundsRect;
    ClipCursor(@Rect);
  end
  else
    ClipCursor(nil); //Otherwise have no restriction
  {$ENDIF}
end;


end.
