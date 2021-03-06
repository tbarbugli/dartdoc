// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// A documentation generator for Dart.
///
/// Library interface is currently under heavy construction and may change
/// drastically between minor revisions.
library dartdoc;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartdoc/src/dartdoc_options.dart';
import 'package:dartdoc/src/generator/empty_generator.dart';
import 'package:dartdoc/src/generator/generator.dart';
import 'package:dartdoc/src/generator/html_generator.dart';
import 'package:dartdoc/src/logging.dart';
import 'package:dartdoc/src/model/model.dart';
import 'package:dartdoc/src/package_meta.dart';
import 'package:dartdoc/src/tuple.dart';
import 'package:dartdoc/src/utils.dart';
import 'package:dartdoc/src/version.dart';
import 'package:dartdoc/src/warnings.dart';
import 'package:html/dom.dart' show Element, Document;
import 'package:html/parser.dart' show parse;
import 'package:path/path.dart' as path;

export 'package:dartdoc/src/dartdoc_options.dart';
export 'package:dartdoc/src/element_type.dart';
export 'package:dartdoc/src/generator/generator.dart';
export 'package:dartdoc/src/model/model.dart';
export 'package:dartdoc/src/package_meta.dart';

const String programName = 'dartdoc';
// Update when pubspec version changes by running `pub run build_runner build`
const String dartdocVersion = packageVersion;

/// Helper class that consolidates option contexts for instantiating generators.
class DartdocGeneratorOptionContext extends DartdocOptionContext
    with GeneratorContext {
  DartdocGeneratorOptionContext(DartdocOptionSet optionSet, Directory dir)
      : super(optionSet, dir);
}

class DartdocFileWriter implements FileWriter {
  final String outputDir;
  final Map<String, Warnable> _fileElementMap = {};
  @override
  final Set<String> writtenFiles = Set();

  DartdocFileWriter(this.outputDir);

  @override
  void write(String filePath, Object content,
      {bool allowOverwrite, Warnable element}) {
    // Replace '/' separators with proper separators for the platform.
    String outFile = path.joinAll(filePath.split('/'));

    allowOverwrite ??= false;
    if (!allowOverwrite) {
      if (_fileElementMap.containsKey(outFile)) {
        assert(element != null,
            'Attempted overwrite of ${outFile} without corresponding element');
        Warnable originalElement = _fileElementMap[outFile];
        Iterable<Warnable> referredFrom =
            originalElement != null ? [originalElement] : null;
        element?.warn(PackageWarning.duplicateFile,
            message: outFile, referredFrom: referredFrom);
      }
    }
    _fileElementMap[outFile] = element;

    var file = File(path.join(outputDir, outFile));
    var parent = file.parent;
    if (!parent.existsSync()) {
      parent.createSync(recursive: true);
    }

    if (content is String) {
      file.writeAsStringSync(content);
    } else if (content is List<int>) {
      file.writeAsBytesSync(content);
    } else {
      throw ArgumentError.value(
          content, 'content', '`content` must be `String` or `List<int>`.');
    }

    writtenFiles.add(outFile);
    logProgress(outFile);
  }
}

/// Generates Dart documentation for all public Dart libraries in the given
/// directory.
class Dartdoc extends PackageBuilder {
  final Generator generator;
  final Set<String> writtenFiles = Set();
  Directory outputDir;

  // Fires when the self checks make progress.
  final StreamController<String> _onCheckProgress =
      StreamController(sync: true);

  Dartdoc._(DartdocOptionContext config, this.generator) : super(config) {
    outputDir = Directory(config.output)..createSync(recursive: true);
  }

  /// An asynchronous factory method that builds Dartdoc's file writers
  /// and returns a Dartdoc object with them.
  @Deprecated('Prefer withContext() instead')
  static Future<Dartdoc> withDefaultGenerators(
      DartdocGeneratorOptionContext config) async {
    return Dartdoc._(config, await initHtmlGenerator(config));
  }

  /// Asynchronous factory method that builds Dartdoc with an empty generator.
  static Future<Dartdoc> withEmptyGenerator(DartdocOptionContext config) async {
    return Dartdoc._(config, await initEmptyGenerator(config));
  }

  /// Asynchronous factory method that builds Dartdoc with a generator
  /// determined by the given context.
  static Future<Dartdoc> fromContext(
      DartdocGeneratorOptionContext context) async {
    Generator generator;
    switch (context.format) {
      case 'html':
        generator = await initHtmlGenerator(context);
        break;
      case 'md':
        // TODO(jdkoren): use a real generator
        generator = await initEmptyGenerator(context);
        break;
      default:
        throw DartdocFailure('Unsupported output format: ${context.format}');
    }
    return Dartdoc._(context, generator);
  }

  Stream<String> get onCheckProgress => _onCheckProgress.stream;

  PackageGraph packageGraph;

  /// Generate Dartdoc documentation.
  ///
  /// [DartdocResults] is returned if dartdoc succeeds. [DartdocFailure] is
  /// thrown if dartdoc fails in an expected way, for example if there is an
  /// analysis error in the code.
  Future<DartdocResults> generateDocsBase() async {
    Stopwatch _stopwatch = Stopwatch()..start();
    double seconds;
    packageGraph = await buildPackageGraph();
    seconds = _stopwatch.elapsedMilliseconds / 1000.0;
    int libs = packageGraph.libraries.length;
    logInfo("Initialized dartdoc with ${libs} librar${libs == 1 ? 'y' : 'ies'} "
        "in ${seconds.toStringAsFixed(1)} seconds");
    _stopwatch.reset();

    final generator = this.generator;
    if (generator != null) {
      // Create the out directory.
      if (!outputDir.existsSync()) outputDir.createSync(recursive: true);

      DartdocFileWriter writer = DartdocFileWriter(outputDir.path);
      await generator.generate(packageGraph, writer);

      writtenFiles.addAll(writer.writtenFiles);
      if (config.validateLinks && writtenFiles.isNotEmpty) {
        validateLinks(packageGraph, outputDir.path);
      }
    }

    int warnings = packageGraph.packageWarningCounter.warningCount;
    int errors = packageGraph.packageWarningCounter.errorCount;
    if (warnings == 0 && errors == 0) {
      logInfo("no issues found");
    } else {
      logWarning("found ${warnings} ${pluralize('warning', warnings)} "
          "and ${errors} ${pluralize('error', errors)}");
    }

    seconds = _stopwatch.elapsedMilliseconds / 1000.0;
    libs = packageGraph.localPublicLibraries.length;
    logInfo("Documented ${libs} public librar${libs == 1 ? 'y' : 'ies'} "
        "in ${seconds.toStringAsFixed(1)} seconds");
    return DartdocResults(config.topLevelPackageMeta, packageGraph, outputDir);
  }

  Future<DartdocResults> generateDocs() async {
    logPrint("Documenting ${config.topLevelPackageMeta}...");

    DartdocResults dartdocResults = await generateDocsBase();
    if (dartdocResults.packageGraph.localPublicLibraries.isEmpty) {
      throw DartdocFailure("dartdoc could not find any libraries to document");
    }

    final int errorCount =
        dartdocResults.packageGraph.packageWarningCounter.errorCount;
    if (errorCount > 0) {
      throw DartdocFailure(
          "dartdoc encountered $errorCount errors while processing.");
    }
    logInfo(
        'Success! Docs generated into ${dartdocResults.outDir.absolute.path}');
    return dartdocResults;
  }

  /// Warn on file paths.
  void _warn(PackageGraph packageGraph, PackageWarning kind, String warnOn,
      String origin,
      {String referredFrom}) {
    // Ordinarily this would go in [Package.warn], but we don't actually know what
    // ModelElement to warn on yet.
    Warnable warnOnElement;
    Set<Warnable> referredFromElements = Set();
    Set<Warnable> warnOnElements;

    // Make all paths relative to origin.
    if (path.isWithin(origin, warnOn)) {
      warnOn = path.relative(warnOn, from: origin);
    }
    if (referredFrom != null) {
      if (path.isWithin(origin, referredFrom)) {
        referredFrom = path.relative(referredFrom, from: origin);
      }
      // Source paths are always relative.
      if (_hrefs[referredFrom] != null) {
        referredFromElements.addAll(_hrefs[referredFrom]);
      }
    }
    warnOnElements = _hrefs[warnOn];

    if (referredFromElements.any((e) => e.isCanonical)) {
      referredFromElements.removeWhere((e) => !e.isCanonical);
    }
    if (warnOnElements != null) {
      if (warnOnElements.any((e) => e.isCanonical)) {
        warnOnElement = warnOnElements.firstWhere((e) => e.isCanonical);
      } else {
        // If we don't have a canonical element, just pick one.
        warnOnElement = warnOnElements.isEmpty ? null : warnOnElements.first;
      }
    }

    if (referredFromElements.isEmpty && referredFrom == 'index.html') {
      referredFromElements.add(packageGraph.defaultPackage);
    }
    String message = warnOn;
    if (referredFrom == 'index.json') message = '$warnOn (from index.json)';
    packageGraph.warnOnElement(warnOnElement, kind,
        message: message, referredFrom: referredFromElements);
  }

  void _doOrphanCheck(
      PackageGraph packageGraph, String origin, Set<String> visited) {
    String normalOrigin = path.normalize(origin);
    String staticAssets = path.joinAll([normalOrigin, 'static-assets', '']);
    String indexJson = path.joinAll([normalOrigin, 'index.json']);
    bool foundIndexJson = false;
    for (FileSystemEntity f
        in Directory(normalOrigin).listSync(recursive: true)) {
      var fullPath = path.normalize(f.path);
      if (f is Directory) {
        continue;
      }
      if (fullPath.startsWith(staticAssets)) {
        continue;
      }
      if (fullPath == indexJson) {
        foundIndexJson = true;
        _onCheckProgress.add(fullPath);
        continue;
      }
      if (visited.contains(fullPath)) continue;
      String relativeFullPath = path.relative(fullPath, from: normalOrigin);
      if (!writtenFiles.contains(relativeFullPath)) {
        // This isn't a file we wrote (this time); don't claim we did.
        _warn(packageGraph, PackageWarning.unknownFile, fullPath, normalOrigin);
      } else {
        // Error messages are orphaned by design and do not appear in the search
        // index.
        if (<String>['__404error.html', 'categories.json'].contains(fullPath)) {
          _warn(packageGraph, PackageWarning.orphanedFile, fullPath,
              normalOrigin);
        }
      }
      _onCheckProgress.add(fullPath);
    }

    if (!foundIndexJson) {
      _warn(packageGraph, PackageWarning.brokenLink, indexJson, normalOrigin);
      _onCheckProgress.add(indexJson);
    }
  }

  // This is extracted to save memory during the check; be careful not to hang
  // on to anything referencing the full file and doc tree.
  Tuple2<Iterable<String>, String> _getStringLinksAndHref(String fullPath) {
    File file = File("$fullPath");
    if (!file.existsSync()) {
      return null;
    }
    Document doc = parse(file.readAsBytesSync());
    Element base = doc.querySelector('base');
    String baseHref;
    if (base != null) {
      baseHref = base.attributes['href'];
    }
    List<Element> links = doc.querySelectorAll('a');
    List<String> stringLinks = links
        .map((link) => link.attributes['href'])
        .where((href) => href != null)
        .toList();

    return Tuple2(stringLinks, baseHref);
  }

  void _doSearchIndexCheck(
      PackageGraph packageGraph, String origin, Set<String> visited) {
    String fullPath = path.joinAll([origin, 'index.json']);
    String indexPath = path.joinAll([origin, 'index.html']);
    File file = File("$fullPath");
    if (!file.existsSync()) {
      return null;
    }
    JsonDecoder decoder = JsonDecoder();
    List jsonData = decoder.convert(file.readAsStringSync());

    Set<String> found = Set();
    found.add(fullPath);
    // The package index isn't supposed to be in the search, so suppress the
    // warning.
    found.add(indexPath);
    for (Map<String, dynamic> entry in jsonData) {
      if (entry.containsKey('href')) {
        String entryPath = path.joinAll([origin, entry['href']]);
        if (!visited.contains(entryPath)) {
          _warn(packageGraph, PackageWarning.brokenLink, entryPath,
              path.normalize(origin),
              referredFrom: fullPath);
        }
        found.add(entryPath);
      }
    }
    // Missing from search index
    Set<String> missing_from_search = visited.difference(found);
    for (String s in missing_from_search) {
      _warn(packageGraph, PackageWarning.missingFromSearchIndex, s,
          path.normalize(origin),
          referredFrom: fullPath);
    }
  }

  void _doCheck(PackageGraph packageGraph, String origin, Set<String> visited,
      String pathToCheck,
      [String source, String fullPath]) {
    if (fullPath == null) {
      fullPath = path.joinAll([origin, pathToCheck]);
      fullPath = path.normalize(fullPath);
    }

    Tuple2 stringLinksAndHref = _getStringLinksAndHref(fullPath);
    if (stringLinksAndHref == null) {
      _warn(packageGraph, PackageWarning.brokenLink, pathToCheck,
          path.normalize(origin),
          referredFrom: source);
      _onCheckProgress.add(pathToCheck);
      // Remove so that we properly count that the file doesn't exist for
      // the orphan check.
      visited.remove(fullPath);
      return null;
    }
    visited.add(fullPath);
    Iterable<String> stringLinks = stringLinksAndHref.item1;
    String baseHref = stringLinksAndHref.item2;

    // Prevent extremely large stacks by storing the paths we are using
    // here instead -- occasionally, very large jobs have overflowed
    // the stack without this.
    // (newPathToCheck, newFullPath)
    Set<Tuple2<String, String>> toVisit = Set();

    final RegExp ignoreHyperlinks = RegExp(r'^(https:|http:|mailto:|ftp:)');
    for (String href in stringLinks) {
      if (!href.startsWith(ignoreHyperlinks)) {
        Uri uri;
        try {
          uri = Uri.parse(href);
        } catch (FormatError) {
          // ignore
        }

        if (uri == null || !uri.hasAuthority && !uri.hasFragment) {
          var full;
          if (baseHref != null) {
            full = '${path.dirname(pathToCheck)}/$baseHref/$href';
          } else {
            full = '${path.dirname(pathToCheck)}/$href';
          }
          var newPathToCheck = path.normalize(full);
          String newFullPath = path.joinAll([origin, newPathToCheck]);
          newFullPath = path.normalize(newFullPath);
          if (!visited.contains(newFullPath)) {
            toVisit.add(Tuple2(newPathToCheck, newFullPath));
            visited.add(newFullPath);
          }
        }
      }
    }
    for (Tuple2 visitPaths in toVisit) {
      _doCheck(packageGraph, origin, visited, visitPaths.item1, pathToCheck,
          visitPaths.item2);
    }
    _onCheckProgress.add(pathToCheck);
  }

  Map<String, Set<ModelElement>> _hrefs;

  /// Don't call this method more than once, and only after you've
  /// generated all docs for the Package.
  void validateLinks(PackageGraph packageGraph, String origin) {
    assert(_hrefs == null);
    _hrefs = packageGraph.allHrefs;

    final Set<String> visited = Set();
    final String start = 'index.html';
    logInfo('Validating docs...');
    _doCheck(packageGraph, origin, visited, start);
    _doOrphanCheck(packageGraph, origin, visited);
    _doSearchIndexCheck(packageGraph, origin, visited);
  }
}

/// This class is returned if dartdoc fails in an expected way (for instance, if
/// there is an analysis error in the library).
class DartdocFailure {
  final String message;

  DartdocFailure(this.message);

  @override
  String toString() => message;
}

/// The results of a [Dartdoc.generateDocs] call.
class DartdocResults {
  final PackageMeta packageMeta;
  final PackageGraph packageGraph;
  final Directory outDir;

  DartdocResults(this.packageMeta, this.packageGraph, this.outDir);
}
