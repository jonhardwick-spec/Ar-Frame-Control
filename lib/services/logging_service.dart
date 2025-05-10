import 'package:logging/logging.dart';

class LoggingService {
  static final Logger _loggerError = Logger("ERROR");
  static final Logger _loggerInfo = Logger("INFO");
  static final Logger _loggerWarn = Logger("WARN");

  static void logInfo(String message) {
    _loggerError.log(Level.INFO, message);
  }

  static void logError(String message) {
    _loggerError.log(Level.SEVERE, message);
  }

  static void logWarning(String message) {
    _loggerError.log(Level.WARNING, message);
  }
}