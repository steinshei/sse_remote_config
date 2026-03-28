import 'package:mmkv/mmkv.dart';

Future<void> ensurePlatformStorageReady() => MMKV.initialize();
