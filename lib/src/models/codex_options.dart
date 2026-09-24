/// Configuration for the Codex CLI translation provider.
class CodexOptions {
  static const String defaultExecutable = 'codex';
  static const int defaultTimeoutSeconds = 900;
  static const int defaultMaxAgents = 3;

  /// Changes of at most this many resources are translated for every target
  /// locale in a single Codex run instead of one run per locale. 0 disables it.
  static const int defaultBatchMaxResources = 20;
  static const Set<String> allowedReasoningEfforts = {
    'none',
    'minimal',
    'low',
    'medium',
    'high',
    'xhigh',
    'max',
    'ultra',
  };

  final String executable;
  final String? model;
  final String? reasoningEffort;
  final Duration timeout;
  final int maxAgents;
  final int batchMaxResources;

  const CodexOptions({
    this.executable = defaultExecutable,
    this.model,
    this.reasoningEffort,
    this.timeout = const Duration(seconds: defaultTimeoutSeconds),
    this.maxAgents = defaultMaxAgents,
    this.batchMaxResources = defaultBatchMaxResources,
  });

  factory CodexOptions.fromConfig({
    String? executable,
    String? model,
    String? reasoningEffort,
    int timeoutSeconds = defaultTimeoutSeconds,
    int maxAgents = defaultMaxAgents,
    int batchMaxResources = defaultBatchMaxResources,
  }) {
    final normalizedExecutable = executable?.trim();
    final normalizedModel = model?.trim();
    final normalizedReasoningEffort = reasoningEffort?.trim();

    final options = CodexOptions(
      executable:
          normalizedExecutable == null || normalizedExecutable.isEmpty ? defaultExecutable : normalizedExecutable,
      model: normalizedModel == null || normalizedModel.isEmpty ? null : normalizedModel,
      reasoningEffort:
          normalizedReasoningEffort == null || normalizedReasoningEffort.isEmpty ? null : normalizedReasoningEffort,
      timeout: Duration(seconds: timeoutSeconds),
      maxAgents: maxAgents,
      batchMaxResources: batchMaxResources,
    );
    options.validate();
    return options;
  }

  /// Validates both parsed configuration and direct programmatic instances.
  void validate() {
    if (timeout.inSeconds < 1) {
      throw ArgumentError.value(
        timeout.inSeconds,
        'timeout',
        'must be at least 1',
      );
    }
    if (maxAgents < 2) {
      throw ArgumentError.value(
        maxAgents,
        'maxAgents',
        'must be at least 2 so translation and verification are independent',
      );
    }
    if (maxAgents > 16) {
      throw ArgumentError.value(
        maxAgents,
        'maxAgents',
        'must not exceed 16',
      );
    }
    if (batchMaxResources < 0) {
      throw ArgumentError.value(
        batchMaxResources,
        'batchMaxResources',
        'must be 0 (disabled) or positive',
      );
    }
    if (reasoningEffort != null && reasoningEffort!.isNotEmpty && !allowedReasoningEfforts.contains(reasoningEffort)) {
      throw ArgumentError.value(
        reasoningEffort,
        'reasoningEffort',
        'must be one of ${allowedReasoningEfforts.join(', ')}',
      );
    }
  }

  /// All settings that can change a generated translation. [batchMaxResources]
  /// only changes how requests are grouped, so it is deliberately excluded:
  /// changing it must not invalidate existing translations.
  String get cacheIdentity => <String>[
        model ?? 'configured-default',
        'reasoning=${reasoningEffort ?? 'configured-default'}',
        'agents=$maxAgents',
      ].join(';');
}
