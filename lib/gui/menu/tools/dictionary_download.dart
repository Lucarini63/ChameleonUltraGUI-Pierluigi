import 'dart:convert';
import 'dart:io';

import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/helpers/dictionary_download.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

// Localizations
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';

class DictionaryDownloadMenu extends StatefulWidget {
  const DictionaryDownloadMenu({super.key});

  @override
  State<DictionaryDownloadMenu> createState() => DictionaryDownloadMenuState();
}

class DictionaryDownloadMenuState extends State<DictionaryDownloadMenu> {
  final ScrollController _scrollController = ScrollController();
  final Set<String> _downloading = <String>{};
  bool _importing = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _downloadDictionary(ChameleonGUIState appState,
      DictionaryLocation dictLocation, AppLocalizations localizations) async {
    setState(() {
      _downloading.add(dictLocation.url);
    });

    try {
      final dict = await downloadDictionary(dictLocation);

      if (dict != null) {
        var dictionaries = appState.sharedPreferencesProvider.getDictionaries();
        // Replace an existing dictionary with the same name instead of adding a
        // duplicate copy, so repeated downloads don't pile up identical entries.
        final existingIndex =
            dictionaries.indexWhere((entry) => entry.name == dict.name);
        if (existingIndex >= 0) {
          dictionaries[existingIndex] = dict;
        } else {
          dictionaries.add(dict);
        }
        appState.sharedPreferencesProvider.setDictionaries(dictionaries);
        appState.changesMade();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(localizations
                    .dictionary_download_success(dictLocation.name))),
          );
        }
      }
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() {
          _downloading.remove(dictLocation.url);
        });
      }
    }
  }

  Future<void> _importDictionary(
      ChameleonGUIState appState, AppLocalizations localizations) async {
    setState(() => _importing = true);

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['dic'],
        withData: true,
      );
      if (result == null) {
        return;
      }

      final selectedFile = result.files.single;
      final bytes = selectedFile.bytes ??
          (selectedFile.path == null
              ? null
              : await File(selectedFile.path!).readAsBytes());
      if (bytes == null) {
        throw const FileSystemException('Unable to read selected file');
      }

      final contents = const Utf8Decoder().convert(bytes);
      final name = selectedFile.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
      final dictionary = Dictionary.fromString(contents, name: name);
      if (dictionary.keys.isEmpty) {
        throw const FormatException('No valid keys found');
      }

      final dictionaries = appState.sharedPreferencesProvider.getDictionaries();
      dictionaries.insert(0, dictionary);
      appState.sharedPreferencesProvider.setDictionaries(dictionaries);
      if (dictionary.keyLength == 12) {
        appState.sharedPreferencesProvider
            .setSelectedMifareClassicDictionaryId(dictionary.id);
      }
      appState.changesMade();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(localizations.dictionary_download_success(name)),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        final isItalian = Localizations.localeOf(context).languageCode == 'it';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isItalian
                ? 'Il file .dic non contiene chiavi valide o non può essere letto.'
                : 'The .dic file contains no valid keys or cannot be read.'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _importing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    var appState = context.watch<ChameleonGUIState>();
    var localizations = AppLocalizations.of(context)!;

    const dictionaries = defaultDictionaryLocations;

    return AlertDialog(
      title: Text(localizations.dictionary_download,
          maxLines: 3, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          controller: _scrollController,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              ...List.generate(dictionaries.length, (index) {
                final dict = dictionaries[index];
                final isDownloading = _downloading.contains(dict.url);

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          dict.name,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: isDownloading
                            ? null
                            : () => _downloadDictionary(
                                appState, dict, localizations),
                        child: isDownloading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.download),
                      ),
                    ],
                  ),
                );
              }),
              const Divider(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _importing
                      ? null
                      : () => _importDictionary(appState, localizations),
                  icon: _importing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.upload_file),
                  label: Text(
                    Localizations.localeOf(context).languageCode == 'it'
                        ? 'Importa file .dic'
                        : 'Import .dic file',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        ElevatedButton(
          onPressed: () {
            Navigator.pop(context);
          },
          child: Text(localizations.ok),
        ),
      ],
    );
  }
}
