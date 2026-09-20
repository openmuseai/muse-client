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

  test('seeds the vendored bare-name plugin that patch.yml mounts', () {
    // `name: dsh-model-capabilities` is not under the @muse scope and is not a
    // dependency of dshmarket, so only an explicit seed root gets it into the
    // profile. Without it the packed row resolves to nothing at boot.
    final root = Directory.systemTemp.createTempSync('muse-seed-vendored-');
    addTearDown(() => root.deleteSync(recursive: true));
    File('${root.path}/patch.yml').writeAsStringSync(
      '- insert:\n'
      '    - id: model-capabilities\n'
      '      name: dsh-model-capabilities\n',
    );
    File(
      '${root.path}/closure/node_modules/@deepseek-ai/dsh/package.json',
    )
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({'name': '@deepseek-ai/dsh', 'version': '1.0.0'}),
      );
    File(
      '${root.path}/closure/node_modules/dsh-model-capabilities/package.json',
    )
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'name': 'dsh-model-capabilities'}));
    final dshHome = Directory('${root.path}/dsh-home')..createSync();
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
      File(
        '${dshHome.path}/profiles/web/node_modules/dsh-model-capabilities/package.json',
      ).existsSync(),
      isTrue,
    );
  });

  test('a valid seed marker does not keep leaked host packages alive', () {
    // The generation marker stays valid across boots, so seedClosurePlugins
    // returns early and a scope that leaked in afterwards would shadow the
    // installation fallback forever: Node resolves @deepseek-ai/* from the
    // profile first and dies with ERR_MODULE_NOT_FOUND ("Did you mean
    // …/lib/index.js?") for exactly the leaked packages.
    final root = Directory.systemTemp.createTempSync('muse-seed-leak-');
    addTearDown(() => root.deleteSync(recursive: true));
    File('${root.path}/patch.yml').writeAsStringSync('[]\n');
    File(
      '${root.path}/closure/node_modules/@deepseek-ai/dsh/package.json',
    )
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({'name': '@deepseek-ai/dsh', 'version': '1.0.0'}),
      );
    final dshHome = Directory('${root.path}/dsh-home')..createSync();
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
    // Marker matches the current generation, so the seed below is a no-op.
    Directory('${dshHome.path}/profiles/web').createSync(recursive: true);
    File('${dshHome.path}/profiles/web/.muse-seeded')
        .writeAsStringSync(DshSidecar.closureSeedGeneration(layout));

    final profileLeak = Directory(
      '${dshHome.path}/profiles/web/node_modules/@deepseek-ai/cordis',
    )..createSync(recursive: true);
    File('${profileLeak.path}/index.js').writeAsStringSync('export {}\n');
    final fallback = Directory(
      '${dshHome.path}/profiles/node_modules/@deepseek-ai',
    )..createSync(recursive: true);
    final fallbackLeak = Directory('${fallback.path}/cordis-plugin-timer')
      ..createSync(recursive: true);
    File('${fallbackLeak.path}/index.js').writeAsStringSync('export {}\n');
    // dsh's own proxy packages carry a dsh.moduleFallback record and must stay.
    final proxy = Directory('${fallback.path}/dsh-client-ui-chat')
      ..createSync(recursive: true);
    File('${proxy.path}/package.json').writeAsStringSync(
      jsonEncode({
        'name': '@deepseek-ai/dsh-client-ui-chat',
        'dsh': {
          'moduleFallback': {'targets': <String>[]},
        },
      }),
    );
    var linked = false;
    try {
      Link('${fallback.path}/dsh-client-ui-workflow-run')
          .createSync('${root.path}/closure/node_modules/@deepseek-ai/dsh');
      linked = true;
    } catch (_) {}

    DshSidecar.seedClosurePlugins(layout);
    expect(
      Directory('${dshHome.path}/profiles/web/node_modules/@deepseek-ai')
          .existsSync(),
      isTrue,
      reason: 'the seed is generation-gated, so it leaves the leak in place',
    );

    DshSidecar.clearLeakedHostPackages(layout);
    expect(
      Directory('${dshHome.path}/profiles/web/node_modules/@deepseek-ai')
          .existsSync(),
      isFalse,
      reason: 'the profile must never shadow the installation fallback',
    );
    expect(fallbackLeak.existsSync(), isFalse);
    expect(File('${proxy.path}/package.json').existsSync(), isTrue);
    if (linked) {
      expect(
        FileSystemEntity.typeSync(
          '${fallback.path}/dsh-client-ui-workflow-run',
          followLinks: false,
        ),
        FileSystemEntityType.link,
      );
    }
  });
}
