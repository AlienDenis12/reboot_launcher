import 'dart:async';
import 'dart:io';

import 'package:clipboard/clipboard.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:process_run/shell.dart';
import 'package:reboot_launcher/src/controller/game_controller.dart';
import 'package:reboot_launcher/src/controller/server_controller.dart';
import 'package:reboot_launcher/src/dialog/dialog.dart';
import 'package:reboot_launcher/src/dialog/dialog_button.dart';
import 'package:reboot_launcher/src/dialog/game_dialogs.dart';
import 'package:reboot_launcher/src/dialog/server_dialogs.dart';
import 'package:reboot_launcher/src/model/game_type.dart';
import 'package:reboot_launcher/src/util/os.dart';
import 'package:reboot_launcher/src/util/injector.dart';
import 'package:reboot_launcher/src/util/patcher.dart';
import 'package:reboot_launcher/src/util/reboot.dart';
import 'package:reboot_launcher/src/util/server.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:win32_suspend_process/win32_suspend_process.dart';
import 'package:path/path.dart' as path;

import '../../controller/settings_controller.dart';
import '../../dialog/snackbar.dart';

class LaunchButton extends StatefulWidget {
  const LaunchButton(
      {Key? key})
      : super(key: key);

  @override
  State<LaunchButton> createState() => _LaunchButtonState();
}

class _LaunchButtonState extends State<LaunchButton> {
  final GameController _gameController = Get.find<GameController>();
  final ServerController _serverController = Get.find<ServerController>();
  final SettingsController _settingsController = Get.find<SettingsController>();
  File? _logFile;
  bool _fail = false;

  @override
  void initState() {
    loadBinary("game.txt", true)
        .then((value) => _logFile = value);
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: AlignmentDirectional.bottomCenter,
      child: SizedBox(
        width: double.infinity,
        child: Obx(() => Tooltip(
          message: _gameController.started.value ? "Close the running Fortnite instance" : "Launch a new Fortnite instance",
          child: Button(
              onPressed: _onPressed,
              child: Text(_gameController.started.value ? "Close" : "Launch")
          ),
        )),
      ),
    );
  }

  void _onPressed() async {
    if (_gameController.username.text.isEmpty) {
      showMessage("Missing in-game username");
      _updateServerState(false);
      return;
    }

    if (_gameController.selectedVersionObs.value == null) {
      showMessage("No version is selected");
      _updateServerState(false);
      return;
    }

    if (_gameController.started.value) {
      _onStop();
      return;
    }

    try {
      _updateServerState(true);
      var version = _gameController.selectedVersionObs.value!;
      var hosting = _gameController.type.value == GameType.headlessServer;
      if (version.launcher != null) {
        _gameController.launcherProcess = await Process.start(version.launcher!.path, []);
        Win32Process(_gameController.launcherProcess!.pid).suspend();
      }

      if(hosting){
        await patch(version.executable!);
      }

      if(!mounted){
        _onStop();
        return;
      }

      var result = await _serverController.changeStateInteractive(true);
      if(!result){
        _onStop();
        return;
      }

      if(_logFile != null && await _logFile!.exists()){
        await _logFile!.delete();
      }

      var gamePath = version.executable?.path;
      if(gamePath == null){
        _onError("${version.location.path} no longer contains a Fortnite executable. Did you delete it?", null);
        _onStop();
        return;
      }

      _gameController.gameProcess = await Process.start(gamePath, createRebootArgs(_gameController.username.text, hosting))
        ..exitCode.then((_) => _onEnd())
        ..outLines.forEach(_onGameOutput);
      await _injectOrShowError(Injectable.cranium);

      if(hosting){
        await _showServerLaunchingWarning();
      }
    } catch (exception, stacktrace) {
      _closeDialogIfOpen(false);
      _onError(exception, stacktrace);
      _onStop();
    }
  }

  Future<void> _updateServerState(bool value) async {
    if (_gameController.started.value == value) {
      return;
    }

    _gameController.started(value);
  }

  void _onEnd() {
    if(_fail){
      return;
    }

    _closeDialogIfOpen(false);
    _onStop();
  }

  void _closeDialogIfOpen(bool success) {
    if(!mounted){
      return;
    }

    var route = ModalRoute.of(context);
    if(route == null || route.isCurrent){
      return;
    }

    Navigator.of(context).pop(success);
  }

  Future<void> _showServerLaunchingWarning() async {
    if(!mounted){
      return;
    }

    var result = await showDialog<bool>(
        context: context,
        builder: (context) => InfoDialog.ofOnly(
          text: "Launching headless reboot server...",
          button: DialogButton(
              type: ButtonType.only,
              onTap: () {
                Navigator.of(context).pop(false);
                _onStop();
              }
          )
        )
    );

    if(result != null && result){
      return;
    }

    _onStop();
  }

  void _onGameOutput(String line) {
    if(_logFile != null){
      _logFile!.writeAsString("$line\n", mode: FileMode.append);
    }

    if (line.contains("FOnlineSubsystemGoogleCommon::Shutdown()")) {
      _onStop();
      return;
    }

    if(line.contains("port 3551 failed: Connection refused") || line.contains("Unable to login to Fortnite servers")){
      _fail = true;
      _closeDialogIfOpen(false);
      showBrokenError();
      return;
    }

    if(line.contains("HTTP 400 response from ")){
      _fail = true;
      _closeDialogIfOpen(false);
      showUnsupportedHeadless();
      return;
    }

    if(line.contains("Network failure when attempting to check platform restrictions") || line.contains("UOnlineAccountCommon::ForceLogout")){
      _fail = true;
      _closeDialogIfOpen(false);
      showTokenError();
      return;
    }

    if(line.contains("Region")){
      if(_gameController.type.value == GameType.client){
        _injectOrShowError(Injectable.console);
      }else {
        _injectOrShowError(Injectable.reboot)
            .then((value) => _closeDialogIfOpen(true));
      }
    }
  }

  Future<Object?> _onError(Object exception, StackTrace? stackTrace) async {
    return showDialog(
        context: context,
        builder: (context) => ErrorDialog(
          exception: exception,
          stackTrace: stackTrace,
          errorMessageBuilder: (exception) => "Cannot launch fortnite: $exception"
        )
    );
  }

  void _onStop() {
    _updateServerState(false);
    _gameController.kill();
  }

  Future<void> _injectOrShowError(Injectable injectable) async {
    var gameProcess = _gameController.gameProcess;
    if (gameProcess == null) {
      return;
    }

    try {
      var dllPath = _getDllPath(injectable);
      if(!dllPath.existsSync()) {
        await _downloadMissingDll(injectable);
        if(!dllPath.existsSync()){
          _onDllFail(dllPath);
          return;
        }
      }

      await injectDll(gameProcess.pid, dllPath.path);
    } catch (exception) {
      showSnackbar(
          context,
          Snackbar(
              content: Text("Cannot inject $injectable.dll: $exception", textAlign: TextAlign.center),
              extended: true
          )
      );
      _onStop();
    }
  }

  void _onDllFail(File dllPath) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fail = true;
      _closeDialogIfOpen(false);
      showMissingDllError(path.basename(dllPath.path));
      _onStop();
    });
  }

  File _getDllPath(Injectable injectable){
    switch(injectable){
      case Injectable.reboot:
        return File(_settingsController.rebootDll.text);
      case Injectable.console:
        return File(_settingsController.consoleDll.text);
      case Injectable.cranium:
        return File(_settingsController.craniumDll.text);
    }
  }

  Future<void> _downloadMissingDll(Injectable injectable) async {
    if(injectable != Injectable.reboot){
      await loadBinary("$injectable.dll", true);
      return;
    }

    await downloadRebootDll(0);
  }
}

enum Injectable {
  console,
  cranium,
  reboot
}