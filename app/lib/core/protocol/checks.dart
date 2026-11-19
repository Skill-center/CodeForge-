/// The validators' building blocks for the page protocols (Phase 5 W3): the
/// Dart mirror of the checks in editor/src/protocol/validate.ts, which the
/// terminal protocol (core/terminal/terminal_protocol.dart) shares with the
/// page. Each check returns null for a valid value, or a reason that names
/// the value's path and never quotes it.
///
/// The editor protocol (core/editor/protocol.dart) keeps its own private
/// copies of the same rules, written before these were shared.
library;

/// Returns null when [value] is valid, otherwise a reason naming [path].
typedef Check = String? Function(Object? value, String path);

/// An envelope id: what both pages and the host accept.
final RegExp idPattern = RegExp(r'^[A-Za-z0-9_.:-]{1,64}$');

/// `#RRGGBB` or `#RRGGBBAA`.
final RegExp colorPattern = RegExp(r'^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$');

/// JavaScript's Number.MAX_SAFE_INTEGER: the page cannot represent more.
const int maxSafeInteger = 9007199254740991;

/// What JavaScript's Number.isSafeInteger accepts. JSON decoding gives Dart
/// an int for `7` but a double for `7.0` or `1e3`; JavaScript has one number
/// type, so both must be judged alike.
bool isSafeInteger(Object? value) {
  if (value is int) {
    return value >= -maxSafeInteger && value <= maxSafeInteger;
  }
  if (value is double) {
    return value.isFinite &&
        value == value.truncateToDouble() &&
        value >= -maxSafeInteger &&
        value <= maxSafeInteger;
  }
  return false;
}

Check stringCheck({int? min, int? max, RegExp? pattern, bool lfOnly = false}) {
  return (value, path) {
    if (value is! String) {
      return '$path must be a string';
    }
    if (min != null && value.length < min) {
      return '$path is too short';
    }
    if (max != null && value.length > max) {
      return '$path is too long';
    }
    if (pattern != null && !pattern.hasMatch(value)) {
      return '$path has an invalid format';
    }
    if (lfOnly && value.contains('\r')) {
      return '$path must use \\n line breaks only';
    }
    return null;
  };
}

Check intCheck({int? min, int? max}) {
  return (value, path) {
    if (!isSafeInteger(value)) {
      return '$path must be an integer';
    }
    final number = value as num;
    if (min != null && number < min) {
      return '$path must be ≥ $min';
    }
    if (max != null && number > max) {
      return '$path must be ≤ $max';
    }
    return null;
  };
}

Check numberCheck({num? min, num? max}) {
  return (value, path) {
    if (value is! num || !value.isFinite) {
      return '$path must be a number';
    }
    if (min != null && value < min) {
      return '$path must be ≥ $min';
    }
    if (max != null && value > max) {
      return '$path must be ≤ $max';
    }
    return null;
  };
}

String? boolCheck(Object? value, String path) =>
    value is bool ? null : '$path must be a boolean';

Check oneOfCheck(List<String> values) {
  return (value, path) => value is String && values.contains(value)
      ? null
      : '$path must be one of: ${values.join(', ')}';
}

String? anyValueCheck(Object? value, String path) => null;

/// Strict object: every required field present, optional fields typed, no
/// others.
Check objectCheck(
  Map<String, Check> required, [
  Map<String, Check> optional = const {},
]) {
  return (value, path) {
    if (value is! Map<String, Object?>) {
      return '$path must be an object';
    }
    for (final key in value.keys) {
      if (!required.containsKey(key) && !optional.containsKey(key)) {
        return '$path.$key is not allowed';
      }
    }
    for (final MapEntry(:key, value: check) in required.entries) {
      if (!value.containsKey(key)) {
        return '$path.$key is required';
      }
      final error = check(value[key], '$path.$key');
      if (error != null) {
        return error;
      }
    }
    for (final MapEntry(:key, value: check) in optional.entries) {
      if (value.containsKey(key)) {
        final error = check(value[key], '$path.$key');
        if (error != null) {
          return error;
        }
      }
    }
    return null;
  };
}
