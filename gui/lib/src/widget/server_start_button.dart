import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:get/get.dart';
import 'package:reboot_common/common.dart';
import 'package:reboot_launcher/src/controller/authenticator_controller.dart';
import 'package:reboot_launcher/src/controller/matchmaker_controller.dart';
import 'package:reboot_launcher/src/controller/server_controller.dart';
import 'package:reboot_launcher/src/dialog/implementation/server.dart';
import 'package:reboot_launcher/src/util/translations.dart';

class ServerButton extends StatefulWidget {
  final bool authenticator;
  const ServerButton({Key? key, required this.authenticator}) : super(key: key);

  @override
  State<ServerButton> createState() => _ServerButtonState();
}

class _ServerButtonState extends State<ServerButton> {
  late final ServerController _controller = widget.authenticator ? Get.find<AuthenticatorController>() : Get.find<MatchmakerController>();
  late final StreamController<void> _textController = StreamController.broadcast();
  late final void Function() _listener = () => _textController.add(null);

  @override
  void initState() {
    _controller.port.addListener(_listener);
    super.initState();
  }

  @override
  void dispose() {
    _controller.port.removeListener(_listener);
    _textController.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Align(
      alignment: AlignmentDirectional.bottomCenter,
      child: SizedBox(
          height: 48,
          width: double.infinity,
          child: Button(
              child: Align(
                alignment: Alignment.center,
                child: StreamBuilder(
                    stream: _textController.stream,
                    builder: (context, snapshot) => Obx(() => Text(_buttonText))
                ),
              ),
              onPressed: () => _controller.toggleInteractive()
          )
      )
  );

  String get _buttonText {
    if(_controller.type.value == ServerType.local && _controller.port.text.trim() == _controller.defaultPort){
      return translations.checkServer(_controller.controllerName);
    }

    if(_controller.started.value){
      return translations.stopServer(_controller.controllerName);
    }

    return translations.startServer(_controller.controllerName);
  }
}