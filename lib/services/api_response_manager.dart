import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = Logger("ApiResponseManager");

class ApiResponse {
  final String answer;
  final Map<String, dynamic> aiResponses;
  final double processingTime;
  final String promptUsed;
  final List<String> debugMessages;
  final bool success;
  final String? error;

  ApiResponse({
    required this.answer,
    required this.aiResponses,
    required this.processingTime,
    required this.promptUsed,
    required this.debugMessages,
    required this.success,
    this.error,
  });

  factory ApiResponse.fromJson(Map<String, dynamic> json) {
    return ApiResponse(
      answer: json['answer'] ?? '',
      aiResponses: json['ai_responses'] ?? {},
      processingTime: (json['processing_time'] ?? 0.0).toDouble(),
      promptUsed: json['prompt_used'] ?? '',
      debugMessages: List<String>.from(json['debug_messages'] ?? []),
      success: json['success'] ?? true,
      error: json['error'],
    );
  }

  factory ApiResponse.error(String errorMessage) {
    return ApiResponse(
      answer: '',
      aiResponses: {},
      processingTime: 0.0,
      promptUsed: '',
      debugMessages: [errorMessage],
      success: false,
      error: errorMessage,
    );
  }
}

class ApiResponseManager {
  static final ApiResponseManager _instance = ApiResponseManager._internal();
  factory ApiResponseManager() => _instance;
  ApiResponseManager._internal();

  final StreamController<String> _debugStreamController = StreamController<String>.broadcast();
  final StreamController<ApiResponse> _responseStreamController = StreamController<ApiResponse>.broadcast();

  Stream<String> get debugStream => _debugStreamController.stream;
  Stream<ApiResponse> get responseStream => _responseStreamController.stream;

  String? _apiEndpoint;
  String? _username;
  String? _authKey;
  bool _isProcessing = false;

  bool get isProcessing => _isProcessing;

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _apiEndpoint = prefs.getString('api_endpoint');
    _username = prefs.getString('api_username');
    _authKey = prefs.getString('api_auth_key');

    _addDebugMessage("🔧 ApiResponseManager initialized");
    _addDebugMessage("📡 Endpoint: ${_apiEndpoint ?? 'Not set'}");
    _addDebugMessage("👤 Username: ${_username ?? 'Not set'}");
  }

  void _addDebugMessage(String message) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    final formattedMessage = "[$timestamp] $message";
    _log.info(formattedMessage);
    _debugStreamController.add(formattedMessage);
  }

  Future<bool> authenticate() async {
    if (_apiEndpoint == null || _authKey == null) {
      _addDebugMessage("❌ Missing endpoint or auth key");
      return false;
    }

    try {
      _addDebugMessage("🔐 Authenticating with server...");

      final url = Uri.parse('$_apiEndpoint/auth-$_authKey');
      final response = await http.post(url).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException('Authentication timed out', const Duration(seconds: 10));
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['success'] == true) {
          _addDebugMessage("✅ Authentication successful!");
          return true;
        }
      }

      _addDebugMessage("❌ Authentication failed: ${response.statusCode}");
      return false;
    } catch (e) {
      _addDebugMessage("❌ Authentication error: $e");
      return false;
    }
  }

  Future<bool> updateProfile(Map<String, String> apiKeys) async {
    if (_apiEndpoint == null || _username == null) {
      _addDebugMessage("❌ Missing endpoint or username for profile update");
      return false;
    }

    try {
      _addDebugMessage("📝 Updating profile with API keys...");

      final url = Uri.parse('$_apiEndpoint/profile');
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'username': _username,
          'api_keys': apiKeys,
        }),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        _addDebugMessage("✅ Profile updated successfully!");
        return true;
      }

      _addDebugMessage("❌ Profile update failed: ${response.statusCode}");
      return false;
    } catch (e) {
      _addDebugMessage("❌ Profile update error: $e");
      return false;
    }
  }

  Future<bool> updatePrompt(String prompt) async {
    if (_apiEndpoint == null || _username == null) {
      _addDebugMessage("❌ Missing endpoint or username for prompt update");
      return false;
    }

    try {
      _addDebugMessage("🎯 Updating custom prompt...");

      final url = Uri.parse('$_apiEndpoint/prompt-$_username');
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'prompt': prompt}),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        _addDebugMessage("✅ Prompt updated successfully!");
        return true;
      }

      _addDebugMessage("❌ Prompt update failed: ${response.statusCode}");
      return false;
    } catch (e) {
      _addDebugMessage("❌ Prompt update error: $e");
      return false;
    }
  }

  Future<ApiResponse> processImage(Uint8List imageData, {String? customPrompt}) async {
    if (_isProcessing) {
      _addDebugMessage("⚠️ Already processing an image, please wait...");
      return ApiResponse.error("Already processing an image");
    }

    if (_apiEndpoint == null || _username == null) {
      _addDebugMessage("❌ Missing endpoint or username for image processing");
      return ApiResponse.error("Missing endpoint or username");
    }

    _isProcessing = true;
    final startTime = DateTime.now();

    try {
      _addDebugMessage("🤖 Starting image processing...");
      _addDebugMessage("📊 Image size: ${(imageData.length / 1024).toStringAsFixed(1)} KB");

      final url = Uri.parse('$_apiEndpoint/process');
      final request = http.MultipartRequest('POST', url);

      // Add form fields
      request.fields['username'] = _username!;
      if (customPrompt != null && customPrompt.isNotEmpty) {
        request.fields['prompt'] = customPrompt;
        _addDebugMessage("🎯 Using custom prompt: '${customPrompt.substring(0, customPrompt.length > 50 ? 50 : customPrompt.length)}...'");
      }

      // Add image file
      request.files.add(http.MultipartFile.fromBytes(
        'image',
        imageData,
        filename: 'frame_image.jpg',
      ));

      _addDebugMessage("📤 Sending request to server...");

      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 90), // Long timeout for AI processing
        onTimeout: () {
          throw TimeoutException('Image processing timed out', const Duration(seconds: 90));
        },
      );

      final response = await http.Response.fromStream(streamedResponse);
      final processingDuration = DateTime.now().difference(startTime);

      _addDebugMessage("📥 Received response (${response.statusCode}) in ${processingDuration.inMilliseconds}ms");

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final apiResponse = ApiResponse.fromJson(data);

        _addDebugMessage("✅ Processing successful!");
        _addDebugMessage("🎭 AI services used: ${apiResponse.aiResponses.keys.join(', ')}");
        _addDebugMessage("⏱️ Server processing time: ${apiResponse.processingTime.toStringAsFixed(2)}s");
        _addDebugMessage("📝 Response length: ${apiResponse.answer.length} characters");

        _responseStreamController.add(apiResponse);
        return apiResponse;
      } else {
        final errorMsg = "Server error: ${response.statusCode} - ${response.body}";
        _addDebugMessage("❌ $errorMsg");
        return ApiResponse.error(errorMsg);
      }
    } catch (e) {
      final errorMsg = "Processing error: $e";
      _addDebugMessage("❌ $errorMsg");
      return ApiResponse.error(errorMsg);
    } finally {
      _isProcessing = false;
      final totalDuration = DateTime.now().difference(startTime);
      _addDebugMessage("🏁 Total processing time: ${totalDuration.inMilliseconds}ms");
    }
  }

  Future<bool> checkServerHealth() async {
    if (_apiEndpoint == null) {
      _addDebugMessage("❌ No endpoint configured for health check");
      return false;
    }

    try {
      _addDebugMessage("🩺 Checking server health...");

      final url = Uri.parse('$_apiEndpoint/health');
      final response = await http.get(url).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        _addDebugMessage("✅ Server healthy - Status: ${data['status']}");
        return true;
      }

      _addDebugMessage("⚠️ Server health check failed: ${response.statusCode}");
      return false;
    } catch (e) {
      _addDebugMessage("❌ Health check error: $e");
      return false;
    }
  }

  void dispose() {
    _debugStreamController.close();
    _responseStreamController.close();
  }
}

class TimeoutException implements Exception {
  final String message;
  final Duration timeout;

  TimeoutException(this.message, this.timeout);

  @override
  String toString() => 'TimeoutException: $message after ${timeout.inSeconds}s';
}