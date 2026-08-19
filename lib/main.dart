import 'dart:async';
import 'dart:io';
import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/connector/serial_android.dart';
import 'package:chameleonultragui/connector/serial_ble.dart';
import 'package:chameleonultragui/connector/serial_emulator.dart';
import 'package:chameleonultragui/connector/serial_macos.dart';
import 'package:chameleonultragui/gui/page/tools.dart';
import 'package:chameleonultragui/gui/menu/pages/mfkey32.dart';
import 'package:chameleonultragui/helpers/dictionary_download.dart';
import 'package:chameleonultragui/helpers/file_logger.dart';
import 'package:chameleonultragui/helpers/font.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'connector/serial_native.dart';

// Page imports
import 'package:chameleonultragui/gui/page/home.dart';
import 'package:chameleonultragui/gui/page/saved_cards.dart';
import 'package:chameleonultragui/gui/page/settings.dart';
import 'package:chameleonultragui/gui/page/connect.dart';
import 'package:chameleonultragui/gui/page/debug.dart';
import 'package:chameleonultragui/gui/page/slot_manager.dart';
import 'package:chameleonultragui/gui/page/flashing.dart';
import 'package:chameleonultragui/gui/page/read_card.dart';
import 'package:chameleonultragui/gui/page/write_card.dart';
import 'package:chameleonultragui/gui/page/pending_connection.dart';
import 'package:chameleonultragui/gui/page/automatic_connection.dart';

// Localizations
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';

// Shared Preferences Provider
import 'package:chameleonultragui/sharedprefsprovider.dart';

// Logger
import 'package:logger/logger.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FileLog.init();
  final sharedPreferencesProvider = SharedPreferencesProvider();
  await sharedPreferencesProvider.load();
  await _writeLogSessionHeader(sharedPreferencesProvider);
  runApp(ChameleonGUI(sharedPreferencesProvider));
}

/// Opens every run with the state a bug report needs: version, platform and the
/// dictionaries the app starts with. Without this the log of a key check cannot
/// be told apart from the log of the run before it.
Future<void> _writeLogSessionHeader(
    SharedPreferencesProvider preferences) async {
  if (!FileLog.isActive) return;

  var version = 'unknown';
  try {
    final info = await PackageInfo.fromPlatform();
    version = '${info.version}+${info.buildNumber}';
  } catch (_) {}

  FileLog.note('');
  FileLog.note('===== Chameleon Ultra GUI session start =====');
  FileLog.note('version: $version');
  FileLog.note('platform: ${Platform.operatingSystem} '
      '(${Platform.operatingSystemVersion})');
  FileLog.note('log file: ${FileLog.path}');
  for (final line in describeDictionaryInventory(preferences)) {
    FileLog.note(line);
  }
  await FileLog.flush();
}

class ChameleonGUI extends StatelessWidget {
  // Root Widget
  final SharedPreferencesProvider _sharedPreferencesProvider;
  const ChameleonGUI(this._sharedPreferencesProvider, {super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _sharedPreferencesProvider),
        ChangeNotifierProvider(
          create: (context) => ChameleonGUIState(_sharedPreferencesProvider),
        ),
      ],
      child: MainPage(sharedPreferencesProvider: _sharedPreferencesProvider),
    );
  }
}

class ChameleonGUIState extends ChangeNotifier {
  final SharedPreferencesProvider sharedPreferencesProvider;
  ChameleonGUIState(this.sharedPreferencesProvider);

  SharedPreferencesProvider? _sharedPreferencesProvider;
  Logger? log; // Logger

  // Android uses AndroidSerial, iOS can only use BLESerial
  // The rest (desktops?) can use NativeSerial
  AbstractSerial? connector;
  ChameleonCommunicator? communicator;

  bool devMode = false;
  double? progress; // DFU

  // Flashing easter egg
  bool easterEgg = false;

  GlobalKey navigationRailKey = GlobalKey();
  Size? navigationRailSize;

  void changesMade() {
    notifyListeners();
  }

  void setProgressBar(dynamic value) {
    progress = value;
    notifyListeners();
  }
}

class MainPage extends StatefulWidget {
  const MainPage({super.key, required this.sharedPreferencesProvider});

  final SharedPreferencesProvider sharedPreferencesProvider;

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> with WidgetsBindingObserver {
  var selectedIndex = 0;
  bool _automaticConnectionLoopRunning = false;
  bool _automaticConnectionWasEnabled = false;
  bool? _lastObservedConnectionState;
  int _automaticConnectionGeneration = 0;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => updateNavigationRailWidth(context));
  }

  @override
  void dispose() {
    _automaticConnectionGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (state != AppLifecycleState.resumed) {
      _automaticConnectionGeneration++;
      return;
    }

    if (mounted) {
      final appState = Provider.of<ChameleonGUIState>(context, listen: false);
      _synchronizeAutomaticConnection(appState);
    }
  }

  bool _automaticConnectionEnabled(ChameleonGUIState appState) {
    return appState.sharedPreferencesProvider.isAutomaticConnectionEnabled() &&
        !appState.sharedPreferencesProvider.isEmulatedChameleon();
  }

  void _synchronizeAutomaticConnection(ChameleonGUIState appState) {
    final enabled = _automaticConnectionEnabled(appState) &&
        _lifecycleState == AppLifecycleState.resumed;

    if (!enabled) {
      if (_automaticConnectionWasEnabled) {
        _automaticConnectionGeneration++;
      }
      _automaticConnectionWasEnabled = false;
      return;
    }

    _automaticConnectionWasEnabled = true;
    if (!_automaticConnectionLoopRunning) {
      unawaited(_runAutomaticConnectionLoop(appState));
    }
  }

  Future<void> _runAutomaticConnectionLoop(ChameleonGUIState appState) async {
    _automaticConnectionLoopRunning = true;
    final generation = ++_automaticConnectionGeneration;

    try {
      while (mounted &&
          generation == _automaticConnectionGeneration &&
          _automaticConnectionEnabled(appState) &&
          _lifecycleState == AppLifecycleState.resumed) {
        final connector = appState.connector;
        if (connector == null) break;

        final connected = connector.connected;
        if (_lastObservedConnectionState != connected) {
          final wasKnown = _lastObservedConnectionState != null;
          _lastObservedConnectionState = connected;
          if (wasKnown) appState.changesMade();
        }

        if (connected || connector.pendingConnection) {
          await Future<void>.delayed(const Duration(seconds: 1));
          continue;
        }

        try {
          final devices = await connector.availableChameleons(false);
          if (!mounted || generation != _automaticConnectionGeneration) {
            break;
          }

          final candidates = devices.where((device) => !device.dfu).toList()
            ..sort((first, second) {
              if (first.type == second.type) return 0;
              return first.type == ConnectionType.usb ? -1 : 1;
            });

          if (candidates.isNotEmpty) {
            final device = candidates.first;
            connector.pendingConnection = true;
            appState.changesMade();

            final didConnect =
                await connector.connectSpecificDevice(device.port);
            if (didConnect) {
              appState.communicator =
                  ChameleonCommunicator(appState.log!, port: connector);
              _lastObservedConnectionState = true;
              appState.log
                  ?.i('[AUTO-CONNECT] Chameleon connected on ${device.port}');
            }
          }
        } catch (error, stackTrace) {
          appState.log?.w('[AUTO-CONNECT] Connection attempt failed',
              error: error, stackTrace: stackTrace);
        } finally {
          connector.pendingConnection = false;
          if (mounted) appState.changesMade();
        }

        await Future<void>.delayed(const Duration(seconds: 2));
      }
    } finally {
      _automaticConnectionLoopRunning = false;
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _synchronizeAutomaticConnection(appState);
        });
      }
    }
  }

  @override
  void reassemble() async {
    // Disconnect on reload
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);
    await appState.connector?.performDisconnect();
    appState.changesMade();

    super.reassemble();
  }

  AbstractSerial getConnector(ChameleonGUIState appState) {
    if (appState._sharedPreferencesProvider!.isEmulatedChameleon()) {
      return EmulatorSerial(log: appState.log!);
    }

    if (Platform.isMacOS) {
      return MacOSSerial(log: appState.log!);
    }

    if (Platform.isAndroid) {
      return AndroidSerial(log: appState.log!);
    }

    if (Platform.isIOS) {
      return BLESerial(log: appState.log!);
    }

    return NativeSerial(log: appState.log!);
  }

  Logger getLogger(ChameleonGUIState appState) {
    // Every line goes to the console and to the log file. The shared
    // preferences sink stays opt-in because it is the slow one.
    final outputs = <LogOutput>[ConsoleOutput(), FileLogOutput()];

    if (appState._sharedPreferencesProvider!.isDebugLogging() &&
        appState._sharedPreferencesProvider!.isDebugMode()) {
      outputs
          .add(SharedPreferencesLogger(appState._sharedPreferencesProvider!));
    }

    return Logger(
      output: MultiOutput(outputs),
      // One timestamped line per entry, no colors and no caller frames: the
      // file has to stay readable in a text editor and filterable by tag.
      printer: PlainLogPrinter(),
      // The default filter drops everything in a release build, which would
      // leave the log file empty exactly where it is needed.
      filter: ChameleonLogFilter(),
    );
  }

  @override
  Widget build(BuildContext context) {
    var appState = context.watch<ChameleonGUIState>();
    appState._sharedPreferencesProvider = widget.sharedPreferencesProvider;
    appState.log ??= getLogger(appState);
    appState.connector ??= getConnector(appState);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _synchronizeAutomaticConnection(appState);
    });

    if (appState.sharedPreferencesProvider.getSideBarAutoExpansion()) {
      double width = MediaQuery.of(context).size.width;
      if (width >= 600) {
        appState.sharedPreferencesProvider.setSideBarExpanded(true);
      } else {
        appState.sharedPreferencesProvider.setSideBarExpanded(false);
      }
    }

    appState.devMode = appState.sharedPreferencesProvider.isDebugMode();

    Widget page; // Set Page
    if (!appState.connector!.connected &&
        selectedIndex != 0 &&
        selectedIndex != 2 &&
        selectedIndex != 6 &&
        selectedIndex != 7 &&
        selectedIndex != 8) {
      // If not connected, and not on home, tools, settings or dev page, go to home page
      selectedIndex = 0;
    }

    switch (selectedIndex) {
      // Sidebar Navigation
      case 0:
        if (appState.connector!.pendingConnection) {
          page = const PendingConnectionPage();
        } else {
          if (appState.connector!.connected) {
            if (appState.connector!.isDFU) {
              page = const FlashingPage();
            } else {
              page = const HomePage();
            }
          } else {
            page = _automaticConnectionEnabled(appState)
                ? const AutomaticConnectionPage()
                : const ConnectPage();
          }
        }
        break;
      case 1:
        page = const SlotManagerPage();
        break;
      case 2:
        page = const SavedCardsPage();
        break;
      case 3:
        page = const Mfkey32Menu();
        break;
      case 4:
        page = const ReadCardPage();
        break;
      case 5:
        page = const WriteCardPage();
        break;
      case 6:
        page = const ToolsPage();
        break;
      case 7:
        page = const SettingsMainPage();
        break;
      case 8:
        page = const DebugPage();
        break;
      default:
        throw UnimplementedError('no widget for $selectedIndex');
    }

    try {
      WakelockPlus.toggle(enable: page is FlashingPage);
    } catch (_) {}

    return MaterialApp(
      title: 'Chameleon Ultra GUI', // App Name
      locale: widget.sharedPreferencesProvider.getLocale(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
            seedColor: widget.sharedPreferencesProvider.getThemeColor()),
        brightness: Brightness.light,
        appBarTheme: AppBarTheme(
            systemOverlayStyle: SystemUiOverlayStyle(
                statusBarColor: ColorScheme.fromSeed(
                        seedColor:
                            widget.sharedPreferencesProvider.getThemeColor(),
                        brightness: Brightness.light)
                    .surface,
                statusBarBrightness: Brightness.light,
                statusBarIconBrightness: Brightness.dark)),
      ).useCustomSystemFont(Brightness.light),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
            seedColor: widget.sharedPreferencesProvider.getThemeColor(),
            brightness: Brightness.dark),
        brightness: Brightness.dark,
        appBarTheme: AppBarTheme(
            systemOverlayStyle: SystemUiOverlayStyle(
                statusBarColor: ColorScheme.fromSeed(
                        seedColor:
                            widget.sharedPreferencesProvider.getThemeColor(),
                        brightness: Brightness.dark)
                    .surface,
                statusBarBrightness: Brightness.dark,
                statusBarIconBrightness: Brightness.light)),
      ).useCustomSystemFont(Brightness.dark),
      themeMode: widget.sharedPreferencesProvider.getTheme(), // Dark Theme
      home: LayoutBuilder(// Build Page
          builder: (context, constraints) {
        return SafeArea(
          left: false,
          right: false,
          top: false,
          bottom: true,
          child: Scaffold(
              body: Row(
                children: [
                  (!appState.connector!.isDFU || !appState.connector!.connected)
                      ? SafeArea(
                          child: NavigationRail(
                            key: appState.navigationRailKey,
                            // Sidebar
                            extended: appState.sharedPreferencesProvider
                                .getSideBarExpanded(),
                            destinations: [
                              // Sidebar Items
                              NavigationRailDestination(
                                icon: const Icon(Icons.home),
                                label: Text(
                                    AppLocalizations.of(context)!.home), // Home
                              ),
                              NavigationRailDestination(
                                disabled: !appState.connector!.connected,
                                icon: const Icon(Icons.widgets),
                                label: Text(
                                    AppLocalizations.of(context)!.slot_manager),
                              ),
                              NavigationRailDestination(
                                icon: const Icon(Icons.auto_awesome_motion),
                                label: Text(
                                    AppLocalizations.of(context)!.saved_cards),
                              ),
                              NavigationRailDestination(
                                disabled: !appState.connector!.connected,
                                icon: const Icon(Icons.lock_open),
                                label: const Text('MFKEY32'),
                              ),
                              NavigationRailDestination(
                                disabled: !appState.connector!.connected,
                                icon: const Icon(Icons.sensors),
                                label: Text(
                                    AppLocalizations.of(context)!.read_card),
                              ),
                              NavigationRailDestination(
                                disabled: !appState.connector!.connected,
                                icon: const Icon(Icons.system_update_alt),
                                label: Text(
                                    AppLocalizations.of(context)!.write_card),
                              ),
                              NavigationRailDestination(
                                icon: const Icon(Icons.handyman),
                                label:
                                    Text(AppLocalizations.of(context)!.tools),
                              ),
                              NavigationRailDestination(
                                icon: const Icon(Icons.settings),
                                label: Text(
                                    AppLocalizations.of(context)!.settings),
                              ),
                              if (appState.devMode)
                                NavigationRailDestination(
                                  icon: const Icon(Icons.bug_report),
                                  label: Text(
                                      '🐞 ${AppLocalizations.of(context)!.debug} 🐞'),
                                ),
                            ],
                            selectedIndex: selectedIndex,
                            onDestinationSelected: (value) {
                              setState(() {
                                selectedIndex = value;
                              });
                            },
                          ),
                        )
                      : const SizedBox(),
                  Expanded(
                    child: Container(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      child: page,
                    ),
                  ),
                ],
              ),
              bottomNavigationBar: const BottomProgressBar()),
        );
      }),
    );
  }
}

class BottomProgressBar extends StatelessWidget {
  const BottomProgressBar({super.key});

  @override
  Widget build(BuildContext context) {
    var appState = context.watch<ChameleonGUIState>();
    return (appState.connector!.connected && appState.connector!.isDFU)
        ? LinearProgressIndicator(
            value: appState.progress,
            backgroundColor: Colors.grey[300],
            valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
          )
        : const SizedBox();
  }
}
