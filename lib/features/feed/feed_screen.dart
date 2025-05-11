import 'package:flutter/material.dart';
import '../../services/frame_service.dart';

class FeedScreen extends StatefulWidget {
  final FrameService frameService;
  const FeedScreen({super.key, required this.frameService});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: ElevatedButton(
        onPressed: () async {
          if (!mounted) return;
          try {
            final photoData = await widget.frameService.capturePhoto();
            if (!mounted) return;
            if (photoData.isNotEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Photo captured: ${photoData.length} bytes')),
            );} else {
              SnackBar(content: Text('Error: PhotoData Null'));
            }
          } catch (e) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error: $e')),
            );
          }
        },
        child: const Text('Capture Photo'),
      ),
    );
  }
}