/// Error returned by the iAlert API (`{ message, code, errors? }`) or raised by the SDK.
class IAlertException implements Exception {
  IAlertException(this.status, this.code, this.message, [this.errors]);

  /// HTTP status, or 0 for SDK-side and network errors.
  final int status;
  final String code;
  final String message;
  final Map<String, List<String>>? errors;

  @override
  String toString() => 'IAlertException($status, $code): $message';
}
