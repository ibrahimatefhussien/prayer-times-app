import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

final FlutterLocalNotificationsPlugin notificationsPlugin =
    FlutterLocalNotificationsPlugin();

const int ongoingPrayerNotificationId = 1001;
const String ongoingChannelId = 'next_prayer_ongoing_channel';
const String ongoingChannelName = 'الصلاة القادمة المثبتة';
const String prefPinNotificationKey = 'pin_next_prayer_notification';
const String versionJsonUrl =
    'https://raw.githubusercontent.com/ibrahimatefhussier/prayer-times-app/main/version.json';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initNotifications();
  runApp(const PrayerTimesApp());
}

Future<void> _initNotifications() async {
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidSettings);
  await notificationsPlugin.initialize(initSettings);

  const channel = AndroidNotificationChannel(
    ongoingChannelId,
    ongoingChannelName,
    description: 'إشعار مثبت يعرض الصلاة القادمة والوقت المتبقي لها',
    importance: Importance.low,
    playSound: false,
    enableVibration: false,
    showBadge: false,
  );

  final androidPlugin = notificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  await androidPlugin?.createNotificationChannel(channel);
  await androidPlugin?.requestNotificationsPermission();
}

class PrayerTimesApp extends StatelessWidget {
  const PrayerTimesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'مواقيت الصلاة',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F5132)),
        useMaterial3: true,
      ),
      home: const Directionality(
        textDirection: TextDirection.rtl,
        child: PrayerHomeScreen(),
      ),
    );
  }
}

class CityOption {
  final String label;
  final String city;
  final String country;
  final int method;

  const CityOption({
    required this.label,
    required this.city,
    required this.country,
    this.method = 5,
  });
}

class PrayerHomeScreen extends StatefulWidget {
  const PrayerHomeScreen({super.key});

  @override
  State<PrayerHomeScreen> createState() => _PrayerHomeScreenState();
}

class _PrayerHomeScreenState extends State<PrayerHomeScreen>
    with WidgetsBindingObserver {
  static const int currentVersionCode = 1;

  final List<CityOption> cities = const [
    CityOption(label: 'القاهرة، مصر', city: 'Cairo', country: 'Egypt', method: 5),
    CityOption(label: 'الإسكندرية، مصر', city: 'Alexandria', country: 'Egypt', method: 5),
    CityOption(label: 'الجيزة، مصر', city: 'Giza', country: 'Egypt', method: 5),
    CityOption(label: 'مكة المكرمة، السعودية', city: 'Makkah', country: 'Saudi Arabia', method: 4),
    CityOption(label: 'المدينة المنورة، السعودية', city: 'Madinah', country: 'Saudi Arabia', method: 4),
    CityOption(label: 'الرياض، السعودية', city: 'Riyadh', country: 'Saudi Arabia', method: 4),
    CityOption(label: 'دبي، الإمارات', city: 'Dubai', country: 'UAE', method: 2),
    CityOption(label: 'عمّان، الأردن', city: 'Amman', country: 'Jordan', method: 3),
    CityOption(label: 'الكويت', city: 'Kuwait', country: 'Kuwait', method: 9),
  ];

  CityOption? selectedCity;
  String locationTitle = 'جاري تحديد موقعك...';
  bool isUsingGps = true;
  bool isNotificationPinned = true;

  bool isUpdateRequired = false;
  String updateVersionName = '';
  String updateApkUrl = '';
  String updateNotes = '';

  Map<String, String>? timings;
  String hijriDate = '';
  String gregorianDate = '';
  String nextPrayerName = '--';
  String countdownText = '00:00:00';
  String remainingHhMm = '00:00';
  String? activePrayerKey;
  bool isLoading = true;
  String? errorMessage;
  Timer? timer;
  int _lastNotifiedMinuteKey = -1;

  final Map<String, String> prayerNamesAr = const {
    'Fajr': 'الفجر',
    'Sunrise': 'الشروق',
    'Dhuhr': 'الظهر',
    'Asr': 'العصر',
    'Maghrib': 'المغرب',
    'Isha': 'العشاء',
  };

  final List<String> prayerOrder = const [
    'Fajr',
    'Sunrise',
    'Dhuhr',
    'Asr',
    'Maghrib',
    'Isha',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeApp();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkForMandatoryUpdate().then((blocked) {
        if (!blocked && isNotificationPinned) {
          _syncOngoingNotification(force: true);
        }
      });
    }
  }

  Future<void> _initializeApp() async {
    await _loadPinPreferenceAndStart();
    await _checkForMandatoryUpdate();
  }

  Future<bool> _checkForMandatoryUpdate() async {
    try {
      final uri = Uri.parse(
        '$versionJsonUrl?t=${DateTime.now().millisecondsSinceEpoch}',
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 6));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final remoteCode =
            int.tryParse(data['latest_version_code'].toString()) ?? currentVersionCode;
        final forceUpdate = data['force_update'] == true;

        if (remoteCode > currentVersionCode && forceUpdate) {
          timer?.cancel();
          if (mounted) {
            setState(() {
              isUpdateRequired = true;
              isLoading = false;
              updateVersionName = (data['latest_version_name'] ?? '').toString();
              updateApkUrl = (data['apk_url'] ?? '').toString();
              updateNotes = (data['notes'] ?? 'يتوفر تحديث جديد، يرجى التحديث للمتابعة.')
                  .toString();
            });
          }
          return true;
        }
      }
    } catch (_) {
      // لا يوجد إنترنت: نكمل تشغيل التطبيق بشكل طبيعي دون إجبار على النت
    }
    return false;
  }

  Future<void> _loadPinPreferenceAndStart() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPin = prefs.getBool(prefPinNotificationKey) ?? true;
    await prefs.setBool(prefPinNotificationKey, savedPin);

    if (!mounted) return;
    setState(() {
      isNotificationPinned = savedPin;
    });

    if (!savedPin) {
      await notificationsPlugin.cancel(ongoingPrayerNotificationId);
    }

    await fetchByGps();
  }

  Future<void> _togglePinNotification(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefPinNotificationKey, value);

    if (!mounted) return;
    setState(() {
      isNotificationPinned = value;
      _lastNotifiedMinuteKey = -1;
    });

    if (value) {
      await _syncOngoingNotification(force: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم تثبيت إشعار الصلاة القادمة في شريط الحالة')),
        );
      }
    } else {
      await notificationsPlugin.cancel(ongoingPrayerNotificationId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم إزالة الإشعار المثبت من داخل التطبيق')),
        );
      }
    }
  }

  Future<void> _syncOngoingNotification({bool force = false}) async {
    if (isUpdateRequired ||
        !isNotificationPinned ||
        timings == null ||
        nextPrayerName == '--') {
      return;
    }

    final now = DateTime.now();
    final minuteBucket = now.year * 1000000 +
        now.month * 10000 +
        now.day * 100 +
        now.hour * 60 +
        now.minute;

    if (!force && minuteBucket == _lastNotifiedMinuteKey) {
      return;
    }
    _lastNotifiedMinuteKey = minuteBucket;

    final prayerTime24 =
        activePrayerKey != null ? (timings![activePrayerKey] ?? '') : '';
    final formattedTime = prayerTime24.isNotEmpty ? format12Hour(prayerTime24) : '';

    const androidDetails = AndroidNotificationDetails(
      ongoingChannelId,
      ongoingChannelName,
      channelDescription: 'إشعار مثبت يعرض الصلاة القادمة والوقت المتبقي لها',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      onlyAlertOnce: true,
      playSound: false,
      enableVibration: false,
      showWhen: false,
    );

    const details = NotificationDetails(android: androidDetails);

    await notificationsPlugin.show(
      ongoingPrayerNotificationId,
      'الصلاة القادمة: $nextPrayerName ($formattedTime)',
      'متبقي: $remainingHhMm  •  $locationTitle',
      details,
    );
  }

  Future<void> fetchByGps() async {
    if (isUpdateRequired) return;

    setState(() {
      isLoading = true;
      errorMessage = null;
      isUsingGps = true;
      locationTitle = 'جاري تحديد موقعك عبر GPS...';
    });

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _fallbackToDefaultCity('خدمة الموقع (GPS) متوقفة، تم عرض مواقيت القاهرة');
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _fallbackToDefaultCity('لم يتم منح صلاحية الموقع، تم عرض مواقيت القاهرة');
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
        ),
      );

      final uri = Uri.parse(
        'https://api.aladhan.com/v1/timings?latitude=${position.latitude}&longitude=${position.longitude}&method=5',
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 12));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        if (decoded['code'] == 200) {
          if (!mounted) return;
          setState(() {
            selectedCity = null;
            locationTitle =
                'موقعك الحالي (${position.latitude.toStringAsFixed(2)}, ${position.longitude.toStringAsFixed(2)})';
          });
          _applyTimingsData(decoded['data'] as Map<String, dynamic>);
          return;
        }
      }

      throw Exception('API Error');
    } catch (_) {
      _fallbackToDefaultCity('تعذر تحديد الموقع تلقائياً، تم عرض مواقيت القاهرة');
    }
  }

  void _fallbackToDefaultCity(String notice) {
    if (!mounted) return;
    final fallback = cities.first;
    setState(() {
      selectedCity = fallback;
      isUsingGps = false;
      locationTitle = fallback.label;
    });
    fetchByCity(fallback, notice: notice);
  }

  Future<void> fetchByCity(CityOption cityOption, {String? notice}) async {
    if (isUpdateRequired) return;

    setState(() {
      isLoading = true;
      errorMessage = null;
      isUsingGps = false;
      selectedCity = cityOption;
      locationTitle = cityOption.label;
    });

    try {
      final uri = Uri.parse(
        'https://api.aladhan.com/v1/timingsByCity?city=${Uri.encodeComponent(cityOption.city)}&country=${Uri.encodeComponent(cityOption.country)}&method=${cityOption.method}',
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 12));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        if (decoded['code'] == 200) {
          _applyTimingsData(decoded['data'] as Map<String, dynamic>);
          if (notice != null && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(notice)),
            );
          }
          return;
        }
      }

      if (!mounted) return;
      setState(() {
        isLoading = false;
        errorMessage = 'تعذر جلب مواقيت الصلاة حالياً';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        isLoading = false;
        errorMessage = 'تأكد من اتصالك بالإنترنت ثم أعد المحاولة';
      });
    }
  }

  void _applyTimingsData(Map<String, dynamic> data) {
    if (!mounted) return;
    final rawTimings = data['timings'] as Map<String, dynamic>;
    final hijri = data['date']['hijri'] as Map<String, dynamic>;
    final gregorian = data['date']['gregorian'] as Map<String, dynamic>;

    final cleanTimings = <String, String>{};
    for (final key in prayerOrder) {
      final raw = (rawTimings[key] ?? '00:00').toString();
      cleanTimings[key] = raw.split(' ').first;
    }

    setState(() {
      timings = cleanTimings;
      hijriDate =
          '${hijri['weekday']['ar']} ${hijri['day']} ${hijri['month']['ar']} ${hijri['year']} هـ';
      gregorianDate = gregorian['date'].toString();
      isLoading = false;
      _lastNotifiedMinuteKey = -1;
    });

    startCountdown();
  }

  DateTime? _parseTodayTime(String hhmm, {int addDays = 0}) {
    final parts = hhmm.split(':');
    if (parts.length < 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;

    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day + addDays, hour, minute);
  }

  void startCountdown() {
    timer?.cancel();
    void updateTick() {
      if (isUpdateRequired || timings == null || !mounted) return;
      final now = DateTime.now();

      String? foundKey;
      DateTime? foundTarget;

      for (final key in prayerOrder) {
        final target = _parseTodayTime(timings![key]!);
        if (target != null && target.isAfter(now)) {
          foundKey = key;
          foundTarget = target;
          break;
        }
      }

      if (foundKey == null) {
        foundKey = 'Fajr';
        foundTarget = _parseTodayTime(timings!['Fajr']!, addDays: 1);
      }

      if (foundTarget != null) {
        final diff = foundTarget.difference(now);
        final hours = diff.inHours.clamp(0, 99).toString().padLeft(2, '0');
        final minutes = (diff.inMinutes % 60).clamp(0, 59).toString().padLeft(2, '0');
        final seconds = (diff.inSeconds % 60).clamp(0, 59).toString().padLeft(2, '0');

        setState(() {
          activePrayerKey = foundKey;
          nextPrayerName = prayerNamesAr[foundKey] ?? foundKey!;
          countdownText = '$hours:$minutes:$seconds';
          remainingHhMm = '$hours:$minutes';
        });

        _syncOngoingNotification();
      }
    }

    updateTick();
    timer = Timer.periodic(const Duration(seconds: 1), (_) => updateTick());
  }

  String format12Hour(String time24) {
    final parts = time24.split(':');
    if (parts.length < 2) return time24;
    final hour24 = int.tryParse(parts[0]) ?? 0;
    final minute = parts[1].padLeft(2, '0');
    final period = hour24 >= 12 ? 'م' : 'ص';
    final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
    return '$hour12:$minute $period';
  }

  @override
  Widget build(BuildContext context) {
    if (isUpdateRequired) {
      return PopScope(
        canPop: false,
        child: Scaffold(
          backgroundColor: const Color(0xFFF4F7F5),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.system_update,
                      size: 64,
                      color: Color(0xFF0F5132),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      updateVersionName.isNotEmpty
                          ? 'تحديث إجباري متاح ($updateVersionName)'
                          : 'تحديث إجباري متاح',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1E293B),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      updateNotes,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 15,
                        color: Color(0xFF64748B),
                      ),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          if (updateApkUrl.isNotEmpty) {
                            final url = Uri.parse(updateApkUrl);
                            if (await canLaunchUrl(url)) {
                              await launchUrl(url, mode: LaunchMode.externalApplication);
                            }
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0F5132),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        icon: const Icon(Icons.download),
                        label: const Text(
                          'تحديث التطبيق الآن',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    const primaryGreen = Color(0xFF0F5132);
    const goldColor = Color(0xFFD4AF37);

    return Scaffold(
      backgroundColor: const Color(0xFFF4F7F5),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 46, 20, 26),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [primaryGreen, Color(0xFF083320)],
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
              ),
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(28),
                bottomRight: Radius.circular(28),
              ),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      isUsingGps ? Icons.my_location : Icons.location_city,
                      color: goldColor,
                      size: 18,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        locationTitle,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  hijriDate.isEmpty ? 'جاري تحميل التاريخ...' : '$hijriDate  |  $gregorianDate',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxWidth: 340),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Column(
                    children: [
                      const Text(
                        'الصلاة القادمة',
                        style: TextStyle(
                          color: goldColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        nextPrayerName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        countdownText,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                activeThumbColor: primaryGreen,
                title: const Text(
                  'تثبيت إشعار الصلاة القادمة في شريط الحالة',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  isNotificationPinned
                      ? 'مثبت (لا يُزال إلا بإغلاقه من هنا)'
                      : 'غير مثبت حالياً',
                  style: const TextStyle(fontSize: 12),
                ),
                value: isNotificationPinned,
                onChanged: _togglePinNotification,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<CityOption>(
                        isExpanded: true,
                        hint: const Text('أو اختر مدينة يدوياً'),
                        value: selectedCity,
                        items: cities
                            .map(
                              (c) => DropdownMenuItem<CityOption>(
                                value: c,
                                child: Text(
                                  c.label,
                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (val) {
                          if (val != null) {
                            fetchByCity(val);
                          }
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: fetchByGps,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.gps_fixed, size: 18),
                  label: const Text('موقعي'),
                ),
              ],
            ),
          ),
          Expanded(
            child: isLoading
                ? const Center(child: CircularProgressIndicator())
                : errorMessage != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(errorMessage!, style: const TextStyle(fontSize: 15)),
                            const SizedBox(height: 10),
                            ElevatedButton(
                              onPressed: fetchByGps,
                              child: const Text('إعادة المحاولة'),
                            ),
                          ],
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
                        itemCount: prayerOrder.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final key = prayerOrder[index];
                          final isActive = key == activePrayerKey;
                          final time24 = timings?[key] ?? '00:00';

                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                            decoration: BoxDecoration(
                              color: isActive ? const Color(0xFFF0FDF4) : Colors.white,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isActive ? goldColor : Colors.transparent,
                                width: isActive ? 1.8 : 1,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.04),
                                  blurRadius: 6,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  prayerNamesAr[key] ?? key,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: isActive ? primaryGreen : const Color(0xFF1E293B),
                                  ),
                                ),
                                Text(
                                  format12Hour(time24),
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                    color: isActive ? primaryGreen : const Color(0xFF0F5132),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
