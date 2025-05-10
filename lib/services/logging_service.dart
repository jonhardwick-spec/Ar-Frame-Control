import 'package:logging/logging.dart';

class LoggingService {
  final Logger _logger = Logger('App');

  Logger get logger => _logger;
}