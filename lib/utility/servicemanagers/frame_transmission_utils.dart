import 'dart:math' as math;

// Frame transmission utilities and constants
class FrameControlBytes {
  static const int CONTINUE = 0x01;
  static const int FINAL = 0x02;
  static const int TERMINATE = 0x03;
  static const int RESET = 0x04;
  static const int HEARTBEAT = 0x05;
  static const int ACK = 0x06;
  static const int NACK = 0x07;
}

class FrameTransmissionUtils {
  // Preprocessing for Frame's constrained Lua environment
  static String preprocessLuaScript(String luaCode) {
    if (luaCode.trim().isEmpty) {
      throw ArgumentError('Lua script cannot be empty');
    }

    // Memory estimation
    final estimatedMemory = luaCode.length * 1.5;
    if (estimatedMemory > 50000) {
      throw ArgumentError('Script may exceed Frame memory limits (estimated: ${estimatedMemory.toStringAsFixed(0)} bytes)');
    }

    // UTF-8 validation
    try {
      luaCode.codeUnits;
    } catch (e) {
      throw ArgumentError('Script contains invalid UTF-8 characters');
    }

    // Optional: Compact whitespace for smaller transmission
    return luaCode.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  // Content-aware chunking for better Lua parsing
  static List<String> createIntelligentChunks(String luaCode, int maxChunkSize) {
    final chunks = <String>[];
    int start = 0;

    while (start < luaCode.length) {
      int end = math.min(start + maxChunkSize, luaCode.length);

      // If not the last chunk, try to break at logical boundaries
      if (end < luaCode.length) {
        // Look for good break points (in order of preference)
        final preferredBreaks = ['\n', ';', ' ', ')'];

        for (final breakChar in preferredBreaks) {
          final lastBreak = luaCode.lastIndexOf(breakChar, end);
          if (lastBreak > start && lastBreak < end) {
            end = lastBreak + 1;
            break;
          }
        }
      }

      chunks.add(luaCode.substring(start, end));
      start = end;
    }

    return chunks;
  }

  static List<String> createSimpleChunks(String text, int maxChunkSize) {
    final chunks = <String>[];
    int index = 0;

    while (index < text.length) {
      int chunkEnd = math.min(index + maxChunkSize, text.length);

      // Don't break in the middle of a Lua token if possible
      if (chunkEnd < text.length) {
        // Try to find a good break point (space, newline, etc.)
        for (int i = chunkEnd; i > index + maxChunkSize * 0.8; i--) {
          if (text[i] == ' ' || text[i] == '\n' || text[i] == ';') {
            chunkEnd = i + 1;
            break;
          }
        }
      }

      chunks.add(text.substring(index, chunkEnd));
      index = chunkEnd;
    }

    return chunks;
  }
}