/// Where a piece of data came from, surfaced to the UI as a status pill.
enum DataSource {
  /// Served by the live backend.
  live('Live', 'Live backend data'),

  /// Backend unreachable; showing mocked fallback data.
  fallback('Mock', 'Showing fallback data (backend unreachable)'),

  /// Backend unreachable and fallback disabled; nothing to show.
  offline('Offline', 'Offline \u2014 no data available'),

  /// Backend responded with an error.
  error('Error', 'Backend error');

  const DataSource(this.label, this.description);

  final String label;
  final String description;
}

/// A value paired with the [DataSource] it came from.
class Sourced<T> {
  const Sourced(this.data, this.source);
  final T data;
  final DataSource source;
}
