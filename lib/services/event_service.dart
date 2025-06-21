import 'dart:async';

/// A singleton class to manage the app's event stream.
class EventService {
  // A private constructor to ensure a single instance.
  EventService._internal();

  // The single, static instance of the service.
  static final EventService _instance = EventService._internal();

  // Factory constructor to return the same instance every time.
  factory EventService() {
    return _instance;
  }

  // The stream controller that manages the event stream.
  // Using .broadcast() allows for multiple listeners.
  final StreamController<AppEvent> _streamController = StreamController<AppEvent>.broadcast();

  /// Exposes the stream for other parts of the app to listen to.
  Stream<T> on<T extends AppEvent>() {
    return _streamController.stream.where((event) => event is T).cast<T>();
  }

  /// Adds an event to the stream to be handled by listeners.
  void fire(AppEvent event) {
    _streamController.add(event);
  }

  /// Call this to dispose the stream controller when the app is closing.
  void dispose() {
    _streamController.close();
  }
}

// ------------------ Event Classes ------------------ //

/// The base class for all events in the application.
abstract class AppEvent {}

/// An event fired periodically to check the device connection.
class HeartbeatEvent extends AppEvent {}

/// An event fired when the bluetooth connection status changes.
class ConnectionChangedEvent extends AppEvent {
  final bool isConnected;
  final String? message;

  ConnectionChangedEvent({required this.isConnected, this.message});
}

/// An event to signal that camera settings may have changed and need to be reloaded/re-applied.
class SettingsChangedEvent extends AppEvent {}