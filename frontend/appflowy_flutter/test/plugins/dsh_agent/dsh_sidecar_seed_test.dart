import 'dart:convert';
import 'dart:io';

import 'package:appflowy/plugins/dsh_agent/dsh_runtime.dart';
import 'package:appflowy/plugins/dsh_agent/dsh_sidecar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('host-owned DSH packages stay out of the profile seed', () {
    expect(DshSidecar.isHostOwnedSeedPackage('@deepseek-ai/cordis'), isTrue);
    expect(
      DshSidecar.isHostOwnedSeedPackage('@deepseek-ai/cordis-plugin-timer'),
      isTrue,
    );
    expect(DshSidecar.isHostOwnedSeedPackage('@muse/dsh-appflowy'), isFalse);
    expect(DshSidecar.isHostOwnedSeedPackage('dshmarket'), isFalse);
    expect(DshSidecar.isHostOwnedSeedPackage('js-yaml'), isFalse);
  });

  test('seed generation changes with install path and overlay stamp', () {
    final root = Directory.systemTemp.createTempSync('muse-seed-gen-');
    addTearDown(() => root.deleteSync(recursive: true));
    final connector = File(
      '${root.path}/closure/node_modules/@muse/dsh-appflowy/dist/src/connector.js',
    )..createSync(recursive: true);
    connector.writeAsStringSync('export {}\n');
    File(
      '${root.path}/closure/node_modules/@deepseek-ai/dsh/package.json',
    )
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'name': '@deepseek-ai/dsh', 'version': '0.1.2'}));
    File('${root.path}/patch.yml').writeAsStringSync('[]\n');
    final layout = DshRuntimeLayout(
      bundled: true,
      museRoot: root.path,
      dshHome: '${root.path}/dsh-home',
      harnessDir: '${root.path}/closure',
      patchFile: '${root.path}/patch.yml',
      nodeBin: '${root.path}/node/node.exe',
      credentialsFile: '${root.path}/credentials.env',
      closureEntry:
          '${root.path}/closure/node_modules/@deepseek-ai/dsh/lib/bin.js',
    );
    final first = DshSidecar.closureSeedGeneration(layout);
    expect(first, contains('0.1.2'));
    expect(first, contains(root.path));
    final moved = DshRuntimeLayout(
      bundled: true,
      museRoot: '${root.path}/elsewhere',
      dshHome: layout.dshHome,
      harnessDir: layout.harnessDir,
      patchFile: layout.patchFile,
      nodeBin: layout.nodeBin,
      credentialsFile: layout.credentialsFile,
      closureEntry: layout.closureEntry,
    );
    expect(DshSidecar.closureSeedGeneration(moved), isNot(first));
  });

  test('re-seed removes a leaked @deepseek-ai profile scope', () {
    final root = Directory.systemTemp.createTempSync('muse-seed-host-');
    addTearDown(() => root.deleteSync(recursive: true));
    File('${root.path}/patch.yml').writeAsStringSync('[]\n');
    File(
      '${root.path}/closure/node_modules/@deepseek-ai/dsh/package.json',
    )
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'name': '@deepseek-ai/dsh', 'version': '1.0.0'}));
    File(
      '${root.path}/closure/node_modules/@muse/dsh-appflowy/package.json',
    )
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'name': '@muse/dsh-appflowy',
          'version': '0.1.0',
          'peerDependencies': {'@deepseek-ai/cordis': '1.0.0'},
        }),
      );
    File(
      '${root.path}/closure/node_modules/@deepseek-ai/cordis/package.json',
    )
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'name': '@deepseek-ai/cordis'}));
    File(
      '${root.path}/closure/node_modules/dshmarket/package.json',
    )
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'name': 'dshmarket'}));
    final dshHome = Directory('${root.path}/dsh-home')..createSync();
    final leaked = Directory(
      '${dshHome.path}/profiles/web/node_modules/@deepseek-ai/cordis',
    )..createSync(recursive: true);
    File('${leaked.path}/package.json').writeAsStringSync('{}');
    File('${dshHome.path}/profiles/web/.muse-seeded').writeAsStringSync('1');
    final layout = DshRuntimeLayout(
      bundled: true,
      museRoot: root.path,
      dshHome: dshHome.path,
      harnessDir: '${root.path}/closure',
      patchFile: '${root.path}/patch.yml',
      nodeBin: '${root.path}/node/node.exe',
      credentialsFile: '${root.path}/credentials.env',
      closureEntry:
          '${root.path}/closure/node_modules/@deepseek-ai/dsh/lib/bin.js',
    );
    DshSidecar.seedClosurePlugins(layout);
    expect(
      Directory(
        '${dshHome.path}/profiles/web/node_modules/@deepseek-ai',
      ).existsSync(),
      isFalse,
    );
    expect(
      File(
        '${dshHome.path}/profiles/web/node_modules/@muse/dsh-appflowy/package.json',
      ).existsSync(),
      isTrue,
    );
    expect(
      File('${dshHome.path}/profiles/web/.muse-seeded').readAsStringSync(),
      DshSidecar.closureSeedGeneration(layout),
    );
  });
}
