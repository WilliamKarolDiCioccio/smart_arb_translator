/// Runs [action] for every item with at most [concurrency] in flight.
///
/// Unlike fixed chunks awaited with `Future.wait`, a finished item frees its
/// slot immediately, so one slow item never holds back the others.
Future<void> forEachPooled<T>(
  Iterable<T> items,
  int concurrency,
  Future<void> Function(T item) action,
) async {
  if (concurrency < 1) {
    throw ArgumentError.value(concurrency, 'concurrency', 'must be >= 1');
  }
  final iterator = items.iterator;
  Future<void> worker() async {
    while (iterator.moveNext()) {
      await action(iterator.current);
    }
  }

  await Future.wait(List.generate(concurrency, (_) => worker()));
}
