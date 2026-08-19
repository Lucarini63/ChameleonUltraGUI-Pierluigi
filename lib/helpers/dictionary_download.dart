import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:http/http.dart' as http;

class DictionaryLocation {
  final String name;
  final String url;

  const DictionaryLocation({
    required this.name,
    required this.url,
  });
}

const List<DictionaryLocation> defaultDictionaryLocations = [
  DictionaryLocation(
    name: 'Proxmark3 (Mifare Classic)',
    url:
        'https://raw.githubusercontent.com/RfidResearchGroup/proxmark3/refs/heads/master/client/dictionaries/mfc_default_keys.dic',
  ),
  DictionaryLocation(
    name: 'Proxmark3 (T55XX)',
    url:
        'https://raw.githubusercontent.com/RfidResearchGroup/proxmark3/refs/heads/master/client/dictionaries/t55xx_default_pwds.dic',
  ),
  DictionaryLocation(
    name: 'Proxmark3 (Mifare Ultralight C)',
    url:
        'https://raw.githubusercontent.com/RfidResearchGroup/proxmark3/refs/heads/master/client/dictionaries/mfulc_default_keys.dic',
  ),
  DictionaryLocation(
    name: 'Proxmark3 (Mifare Plus)',
    url:
        'https://raw.githubusercontent.com/RfidResearchGroup/proxmark3/refs/heads/master/client/dictionaries/mfp_default_keys.dic',
  ),
  DictionaryLocation(
    name: 'Flipper Zero Unleashed Firmware (Mifare Classic)',
    url:
        'https://raw.githubusercontent.com/DarkFlippers/unleashed-firmware/refs/heads/dev/applications/main/nfc/resources/nfc/assets/mf_classic_dict.nfc',
  ),
];

/// One log line per stored dictionary: what is on disk, how long its keys are
/// and which one is marked as selected. Written before a key check so a run can
/// be read back knowing exactly what the app had to work with.
List<String> describeDictionaryInventory(SharedPreferencesProvider preferences) {
  final dictionaries = preferences.getDictionaries();
  final selectedId = preferences.getSelectedMifareClassicDictionaryId();
  final lines = <String>[
    'dictionaries: ${dictionaries.length} stored, '
        'selected id=${selectedId ?? '<none>'}',
  ];

  for (var index = 0; index < dictionaries.length; index++) {
    final dictionary = dictionaries[index];
    lines.add('  [$index] "${dictionary.name}" id=${dictionary.id} '
        'keyLength=${dictionary.keyLength} keys=${dictionary.keys.length}'
        '${dictionary.id == selectedId ? ' <- selected' : ''}');
  }

  return lines;
}

Future<Dictionary?> downloadDictionary(
    DictionaryLocation dictionaryLocation) async {
  final response = await http
      .get(Uri.parse(dictionaryLocation.url))
      .timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) {
    return null;
  }

  final dictionary = Dictionary.fromString(
    response.body,
    name: dictionaryLocation.name,
  );
  return dictionary.keys.isEmpty ? null : dictionary;
}

/// Removes duplicate dictionaries left over from earlier versions, where every
/// download added a fresh copy instead of replacing the existing one. One entry
/// per (name, key length, key count) is kept, preserving the original order.
///
/// Returns true when at least one duplicate was removed.
bool removeDuplicateDictionaries(SharedPreferencesProvider preferences) {
  final dictionaries = preferences.getDictionaries();
  final seen = <String>{};
  final deduped = <Dictionary>[];
  for (final dictionary in dictionaries) {
    final signature = '${dictionary.name}'
        '#${dictionary.keyLength}'
        '#${dictionary.keys.length}';
    if (seen.add(signature)) {
      deduped.add(dictionary);
    }
  }

  if (deduped.length == dictionaries.length) {
    return false;
  }

  preferences.setDictionaries(deduped);
  return true;
}

/// Downloads the built-in dictionaries once, without delaying app startup.
///
/// A failed or partial download is retried on the next launch. Dictionaries
/// already present are left untouched and are never duplicated.
Future<bool> downloadMissingDefaultDictionaries(
    SharedPreferencesProvider preferences) async {
  final existingNames = preferences
      .getDictionaries()
      .map((dictionary) => dictionary.name)
      .toSet();
  final missingLocations = defaultDictionaryLocations
      .where((location) => !existingNames.contains(location.name))
      .toList(growable: false);

  if (missingLocations.isEmpty) {
    preferences.setDefaultDictionariesDownloaded(true);
    return false;
  }

  // The old completion flag may survive a partial restore or the user may
  // have removed a default dictionary. The real dictionary list is the source
  // of truth, so mark the bootstrap incomplete until all entries are present.
  preferences.setDefaultDictionariesDownloaded(false);

  final downloaded = await Future.wait(
    missingLocations.map((location) async {
      try {
        return await downloadDictionary(location);
      } catch (_) {
        return null;
      }
    }),
  );

  final dictionaries = preferences.getDictionaries();
  final currentNames =
      dictionaries.map((dictionary) => dictionary.name).toSet();
  var changed = false;

  for (final dictionary in downloaded.whereType<Dictionary>()) {
    if (currentNames.add(dictionary.name)) {
      dictionaries.add(dictionary);
      changed = true;
    }
  }

  if (changed) {
    preferences.setDictionaries(dictionaries);
  }

  final allDefaultsPresent = defaultDictionaryLocations
      .every((location) => currentNames.contains(location.name));
  if (allDefaultsPresent) {
    preferences.setDefaultDictionariesDownloaded(true);
  }

  return changed;
}

bool areAllDefaultDictionariesPresent(SharedPreferencesProvider preferences) {
  final names = preferences
      .getDictionaries()
      .map((dictionary) => dictionary.name)
      .toSet();
  return defaultDictionaryLocations
      .every((location) => names.contains(location.name));
}
