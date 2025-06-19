import 'dart:isolate';
import 'dart:typed_data';
import 'package:logging/logging.dart';
import 'api_call.dart';

final _log = Logger("FrameProcessingIsolate");

// Message types for communication between main and processing isolates
enum IsolateMessageType {
  initialize,
  processFrame,
  settingsUpdate,
  stop,
  result,
  error,
}

// Data structure for messages sent to the isolate
class IsolateCommand {
  final IsolateMessageType type;
  final dynamic data;

  IsolateCommand(this.type, {this.data});
}

// Data structure for messages received from the isolate
class IsolateResponse {
  final IsolateMessageType type;
  final dynamic data;

  IsolateResponse(this.type, {this.data});
}

// Entry point for the frame processing isolate
void frameProcessingEntryPoint(SendPort mainIsolateSendPort) {
  final ReceivePort isolateReceivePort = ReceivePort();
  mainIsolateSendPort.send(isolateReceivePort.sendPort); // Send back the isolate's sendPort

  String? apiEndpoint;
  int framesToQueue = 5; // Default value, will be updated by settings
  bool processFramesWithApi = false; // New setting for API processing toggle
  final List<Uint8List> frameQueue = [];
  bool isProcessingApi = false;

  // Listen for messages from the main isolate
  isolateReceivePort.listen((dynamic message) async {
    if (message is IsolateCommand) {
      switch (message.type) {
        case IsolateMessageType.initialize:
        // Nothing specific to initialize here beyond setting up port
          _log.info("Processing isolate initialized.");
          break;
        case IsolateMessageType.settingsUpdate:
          if (message.data is Map<String, dynamic>) {
            apiEndpoint = message.data['apiEndpoint'];
            framesToQueue = message.data['framesToQueue'] ?? 5;
            processFramesWithApi = message.data['processFramesWithApi'] ?? false; // Update new setting
            _log.info("Processing isolate settings updated: API: $apiEndpoint, Queue Size: $framesToQueue, Process with API: $processFramesWithApi");
          }
          break;
        case IsolateMessageType.processFrame:
          if (message.data is Uint8List) {
            if (processFramesWithApi) { // Only add to queue if API processing is enabled
              frameQueue.add(message.data);
              _log.fine("Frame added to queue. Current queue size: ${frameQueue.length}");
              if (frameQueue.length >= framesToQueue && !isProcessingApi) {
                await _processQueue(mainIsolateSendPort, apiEndpoint, frameQueue, isProcessingApi);
              }
            } else {
              _log.fine("API processing disabled. Frame not added to queue.");
            }
          }
          break;
        case IsolateMessageType.stop:
          _log.info("Processing isolate stopping.");
          isolateReceivePort.close();
          break;
        default:
          _log.warning("Unknown message type received in isolate: ${message.type}");
      }
    }
  });
}

// Function to process the queue and send frames to the API
Future<void> _processQueue(SendPort mainIsolateSendPort, String? apiEndpoint, List<Uint8List> frameQueue, bool isProcessingApi) async {
  if (isProcessingApi || frameQueue.isEmpty || apiEndpoint == null || apiEndpoint.isEmpty) {
    return;
  }

  isProcessingApi = true;
  _log.info("Processing queue: ${frameQueue.length} frames.");

  try {
    // Take a batch of frames to process
    final List<Uint8List> framesToSend = List.from(frameQueue);
    frameQueue.clear(); // Clear the queue after taking frames

    final apiService = ApiService(endpointUrl: apiEndpoint);

    // For simplicity, we'll send the *last* frame in the batch to the API.
    // In a real scenario, you might send multiple or combine them.
    if (framesToSend.isNotEmpty) {
      final Uint8List frameToProcess = framesToSend.last;
      _log.info("Sending a frame to API: $apiEndpoint");
      final response = await apiService.processImage(imageBytes: frameToProcess);
      _log.info("API Response received in isolate: ${response.substring(0, response.length > 100 ? 100 : response.length)}...");
      mainIsolateSendPort.send(IsolateResponse(IsolateMessageType.result, data: response));
    }
  } catch (e) {
    _log.severe("Error processing frames in isolate: $e");
    mainIsolateSendPort.send(IsolateResponse(IsolateMessageType.error, data: e.toString()));
  } finally {
    isProcessingApi = false;
  }
}