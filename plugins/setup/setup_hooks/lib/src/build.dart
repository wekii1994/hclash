import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'build_cache.dart';
import 'error.dart';
import 'fingerprint.dart';
import 'go_builder.dart';
import 'options.dart';
import 'rust_builder.dart';
import 'target.dart';
import 'util.dart';

final _log = Logger('setup_hooks');

void ensureMihomoPatch(String rootDir) {
  final patchFile = File(p.join(rootDir, 'core', 'patches', 'mihomo-fixes.patch'));
  final submoduleDir = Directory(p.join(rootDir, 'core', 'Clash.Meta'));
  if (!submoduleDir.existsSync()) {
    throw BuildException(
      'Mihomo submodule directory ${submoduleDir.path} does not exist.',
    );
  }
  if (!patchFile.existsSync()) {
    throw BuildException('Patch file ${patchFile.path} not found.');
  }
  final checkResult = Process.runSync(
    'git',
    ['-C', submoduleDir.path, 'apply', '--check', patchFile.path],
  );
  if (checkResult.exitCode == 0) {
    _log.info('Applying Mihomo companion patch to ${submoduleDir.path}...');
    final applyResult = Process.runSync(
      'git',
      ['-C', submoduleDir.path, 'apply', patchFile.path],
    );
    if (applyResult.exitCode != 0) {
      throw BuildException('Failed to apply Mihomo patch: ${applyResult.stderr}');
    }
  } else {
    final reverseCheck = Process.runSync(
      'git',
      ['-C', submoduleDir.path, 'apply', '--reverse', '--check', patchFile.path],
    );
    if (reverseCheck.exitCode != 0) {
      throw BuildException(
        'Mihomo submodule has conflicts or cannot apply companion patch cleanly.',
      );
    }
  }
}

class BuildRequest {
  const BuildRequest({
    required this.rootDir,
    required this.target,
    this.harnessDir,
  });

  final String rootDir;
  final Target target;

  final String? harnessDir;
}

class BuildReport {
  const BuildReport({
    required this.inputs,
    required this.outputs,
    required this.rebuilt,
  });

  final List<String> inputs;
  final List<String> outputs;
  final bool rebuilt;

  /// A directory dependency hashes child names, not content, so a deleted
  /// artifact still reruns the hook without rereading the Core.
  List<String> get outputDirectories =>
      {for (final output in outputs) p.dirname(output)}.toList()..sort();
}

/// The Helper embeds the Core's SHA256, so the Core is built first.
Future<BuildReport> buildPlatform(BuildRequest request) async {
  final stopwatch = Stopwatch()..start();
  final target = request.target;
  final rootDir = request.rootDir;
  final config = BuildConfig.load(rootDir: rootDir);
  final cache = BuildCache(rootDir: rootDir);
  final notice = BuildNotice();
  final harnessInputs = switch (request.harnessDir) {
    null => const <String>[],
    final dir => collectPackageInputs(dir),
  };

  ensureMihomoPatch(rootDir);

  final core = await GoBuilder(
    rootDir: rootDir,
    config: config,
    cache: cache,
    notice: notice,
    harnessInputs: harnessInputs,
  ).build(target);
  if (!target.hasHelper) {
    _log.info('Done in ${stopwatch.elapsed}: ${core.primaryOutput}');
    return _report([core]);
  }

  final coreSha256 = await calcSha256(core.primaryOutput);
  final helper = await RustBuilder(
    rootDir: rootDir,
    config: config,
    cache: cache,
    notice: notice,
    harnessInputs: harnessInputs,
  ).build(target, coreSha256);
  final manifestPath = p.join(
    rootDir,
    config.outputDir,
    target.platformDir,
    coreManifestName,
  );
  writeCoreManifest(path: manifestPath, coreSha256: coreSha256);

  _log.info(
    'Done in ${stopwatch.elapsed}: ${core.primaryOutput}, '
    '${helper.primaryOutput}',
  );
  return _report([core, helper], extraOutputs: [manifestPath]);
}

BuildReport _report(
  List<BuildExecution> results, {
  List<String> extraOutputs = const [],
}) {
  final inputs = <String>{};
  final outputs = <String>{};
  for (final result in results) {
    inputs.addAll(result.inputs);
    outputs.addAll(result.outputs);
  }
  outputs.addAll(extraOutputs);
  return BuildReport(
    inputs: inputs.toList()..sort(),
    outputs: outputs.toList()..sort(),
    rebuilt: results.any((result) => result.rebuilt),
  );
}
