import 'package:flutter/material.dart';
import 'package:ar_project/services/frame_service.dart';

class ConnectButton extends StatelessWidget {
  final VoidCallback onPressed;
  final FrameService frameService;

  const ConnectButton({super.key, required this.onPressed, required this.frameService});

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      onPressed: frameService.connectionState.value ? null : frameService.connectToGlasses,
      backgroundColor: frameService.connectionState.value ? Colors.grey : Colors.blue,
      child: frameService.connectionState.value
          ? const Icon(Icons.bluetooth_connected)
          : const Icon(Icons.bluetooth),

    );
  }
}