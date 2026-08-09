import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:dio/dio.dart';
import 'package:dtrsync/core/network/api_client.dart';

class UserMonthlyAttendanceScreen extends StatefulWidget {
  final int userId;
  final String? userName;

  const UserMonthlyAttendanceScreen({
    super.key,
    required this.userId,
    this.userName,
  });

  @override
  State<UserMonthlyAttendanceScreen> createState() =>
      _UserMonthlyAttendanceScreenState();
}

class _UserMonthlyAttendanceScreenState
    extends State<UserMonthlyAttendanceScreen> {
  DateTime _selectedDate = DateTime.now();
  DateTime _focusedMonth = DateTime.now();

  bool _isCalendarView = true;
  bool _isLoading = true;
  String? _errorMessage;

  late int _loadedYear;
  late int _loadedMonth;

  final Map<DateTime, dynamic> _attendanceRecords = {};
  Map<String, dynamic>? _userProfile;
  double _totalMonthlyHours = 0.0;

  // Cache for reverse geocoding to respect Nominatim rate limits (1 req/sec max)
  final Map<String, String> _addressCache = {};

  // Create a dedicated Dio instance for Nominatim to prevent conflicts
  // with ApiClient and avoid recreating it on every tap.
  static final Dio _geoDio = Dio(
    BaseOptions(
      headers: {
        // ⚠️ REQUIRED BY NOMINATIM: Change this to your ACTUAL developer email!
        'User-Agent': 'DtrSyncApp/1.0 (your_real_email@gmail.com)'
      },
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );

  @override
  void initState() {
    super.initState();
    _loadedYear = _focusedMonth.year;
    _loadedMonth = _focusedMonth.month;
    _fetchMonthlyData(_loadedYear, _loadedMonth);
  }

  Future<void> _fetchMonthlyData(int year, int month) async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _loadedYear = year;
      _loadedMonth = month;
    });

    try {
      final response = await ApiClient.dio.get(
        '/v1/attendances/user/${widget.userId}/monthly',
        queryParameters: {
          'year': year,
          'month': month,
        },
      );

      if (response.statusCode == 200 && response.data != null) {
        _processJsonData(response.data);
      } else {
        _errorMessage =
        "Failed to load data. Server returned ${response.statusCode}.";
      }
    } catch (e) {
      debugPrint("Error fetching monthly attendance: $e");
      _errorMessage = "Failed to connect to the server.";
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _processJsonData(Map<String, dynamic> data) {
    _attendanceRecords.clear();
    final records = data['records'] as List<dynamic>? ?? [];
    _totalMonthlyHours = (data['totalHoursRenderedInMonth'] ?? 0).toDouble();

    for (var record in records) {
      if (record['date'] != null) {
        String rawDate = record['date'].toString();

        if (!rawDate.contains('T')) {
          rawDate = '${rawDate}T00:00:00Z';
        } else if (!rawDate.endsWith('Z')) {
          rawDate = '${rawDate}Z';
        }

        DateTime parsedUtc = DateTime.parse(rawDate).toUtc();
        DateTime phDate = parsedUtc.add(const Duration(hours: 8));

        DateTime normalizedDate =
        DateTime(phDate.year, phDate.month, phDate.day);

        _attendanceRecords[normalizedDate] = record;
        _userProfile ??= record['user'];
      }
    }
  }

  /// Helper: Converts UTC time strings to Philippine Time (UTC+8) formatted string
  String _convertToPhTime(String? dateStr, String? timeStr) {
    if (timeStr == null || timeStr.isEmpty || timeStr == '--:--') {
      return '--:--';
    }

    try {
      DateTime parsedUtc;

      if (timeStr.contains('T')) {
        parsedUtc = DateTime.parse(timeStr).toUtc();
      } else if (dateStr != null && dateStr.isNotEmpty) {
        String shortDate =
        dateStr.contains('T') ? dateStr.split('T')[0] : dateStr;
        parsedUtc = DateTime.parse(
            '${shortDate}T$timeStr${timeStr.length == 5 ? ':00' : ''}Z')
            .toUtc();
      } else {
        parsedUtc = DateTime.parse(
            '1970-01-01T$timeStr${timeStr.length == 5 ? ':00' : ''}Z')
            .toUtc();
      }

      DateTime phTime = parsedUtc.add(const Duration(hours: 8));
      return DateFormat('hh:mm a').format(phTime);
    } catch (e) {
      debugPrint("Error parsing time: $timeStr - $e");
      return timeStr;
    }
  }

  /// Helper: Fetches the street address from OpenStreetMap Nominatim
  Future<String> _fetchAddress(double lat, double lng) async {
    final cacheKey = '${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}';

    if (_addressCache.containsKey(cacheKey)) {
      return _addressCache[cacheKey]!;
    }

    try {
      final response = await _geoDio.get(
        'https://nominatim.openstreetmap.org/reverse',
        queryParameters: {
          'format': 'json',
          'lat': lat,
          'lon': lng,
          'zoom': 18, // 18 is usually street level
          'addressdetails': 1,
        },
      );

      if (response.statusCode == 200 && response.data != null) {
        final data = response.data;
        final addressDetails = data['address'] as Map<String, dynamic>?;

        String resultStr = data['display_name'] ?? 'Unknown address';

        // Try to format a cleaner, shorter address (Street, City)
        if (addressDetails != null) {
          final road =
              addressDetails['road'] ?? addressDetails['pedestrian'] ?? '';
          final city = addressDetails['city'] ??
              addressDetails['town'] ??
              addressDetails['village'] ??
              '';

          if (road.isNotEmpty && city.isNotEmpty) {
            resultStr = '$road, $city';
          } else if (road.isNotEmpty) {
            resultStr = road;
          }
        }

        _addressCache[cacheKey] = resultStr;
        return resultStr;
      }
    } on DioException catch (e) {
      debugPrint("Nominatim Geocoding error: ${e.message}");
      if (e.response?.statusCode == 403) {
        debugPrint("403 Forbidden: Check your User-Agent header in _geoDio!");
      }
    } catch (e) {
      debugPrint("Geocoding fallback error: $e");
    }

    // Fallback to coordinates if network fails or Nominatim rejects the request
    return 'Lat: ${lat.toStringAsFixed(4)}, Lng: ${lng.toStringAsFixed(4)}';
  }

  bool isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: const Text("Monthly Attendance"),
        centerTitle: true,
        elevation: 0,
        backgroundColor: colorScheme.surface,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            child: _buildProfileHeader(colorScheme),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _errorMessage != null
                ? _buildErrorState(colorScheme)
                : _buildMainContent(theme, colorScheme),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(ColorScheme colors) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 48, color: colors.error),
          const SizedBox(height: 16),
          Text(_errorMessage ?? "An error occurred",
              style: TextStyle(color: colors.error)),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () => _fetchMonthlyData(_loadedYear, _loadedMonth),
            icon: const Icon(Icons.refresh),
            label: const Text("Retry"),
          ),
        ],
      ),
    );
  }

  Widget _buildMainContent(ThemeData theme, ColorScheme colors) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= 800;

        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildViewToggle(theme, colors),
              const SizedBox(height: 16),
              if (_isCalendarView) ...[
                if (isDesktop)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 3, child: _buildCalendar(colors)),
                      const SizedBox(width: 24),
                      Expanded(
                          flex: 2, child: _buildSelectedDayDetailCard(colors)),
                    ],
                  )
                else
                  Column(
                    children: [
                      _buildCalendar(colors),
                      const SizedBox(height: 16),
                      _buildSelectedDayDetailCard(colors),
                    ],
                  )
              ] else ...[
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 800),
                    child: _buildListView(colors),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildProfileHeader(ColorScheme colors) {
    final String firstName =
        _userProfile?['firstName'] ?? widget.userName ?? 'Unknown User';
    final String lastName = _userProfile?['lastName'] ?? '';
    final String email = _userProfile?['email'] ?? 'Loading email...';
    final String profilePic = _userProfile?['profilePictureUrl'] ?? '';

    return Row(
      children: [
        CircleAvatar(
          radius: 36,
          backgroundColor: colors.primaryContainer,
          backgroundImage:
          profilePic.isNotEmpty ? NetworkImage(profilePic) : null,
          child: profilePic.isEmpty
              ? Icon(Icons.person, size: 36, color: colors.onPrimaryContainer)
              : null,
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "$firstName $lastName".trim(),
                style:
                const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                email,
                style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Container(
                padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: colors.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  "Monthly Total: ${_totalMonthlyHours.toStringAsFixed(1)} hrs",
                  style: TextStyle(
                    color: colors.onSecondaryContainer,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildViewToggle(ThemeData theme, ColorScheme colors) {
    return Align(
      alignment: Alignment.centerRight,
      child: SegmentedButton<bool>(
        segments: const [
          ButtonSegment<bool>(
            value: true,
            icon: Icon(Icons.calendar_month, size: 18),
            label: Text("Calendar", style: TextStyle(fontSize: 12)),
          ),
          ButtonSegment<bool>(
            value: false,
            icon: Icon(Icons.format_list_bulleted, size: 18),
            label: Text("List", style: TextStyle(fontSize: 12)),
          ),
        ],
        selected: {_isCalendarView},
        onSelectionChanged: (Set<bool> newSelection) {
          setState(() {
            _isCalendarView = newSelection.first;
          });
        },
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  Widget _buildCalendar(ColorScheme colors) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant.withOpacity(0.5)),
        color: colors.surface,
      ),
      child: TableCalendar(
        firstDay: DateTime.utc(2020, 1, 1),
        lastDay: DateTime.utc(2030, 12, 31),
        focusedDay: _focusedMonth,
        calendarFormat: CalendarFormat.month,
        headerStyle:
        const HeaderStyle(titleCentered: true, formatButtonVisible: false),
        selectedDayPredicate: (day) => isSameDay(_selectedDate, day),
        onDaySelected: (selectedDay, focusedDay) {
          setState(() {
            _selectedDate = selectedDay;
            _focusedMonth = focusedDay;
          });
        },
        onPageChanged: (focusedDay) {
          if (focusedDay.year != _loadedYear ||
              focusedDay.month != _loadedMonth) {
            _fetchMonthlyData(focusedDay.year, focusedDay.month);
          }
          setState(() {
            _focusedMonth = focusedDay;
          });
        },
        calendarBuilders: CalendarBuilders(
          defaultBuilder: (context, day, focusedDay) =>
              _buildCalendarCell(day, false, colors),
          todayBuilder: (context, day, focusedDay) =>
              _buildCalendarCell(day, isSameDay(day, _selectedDate), colors),
          selectedBuilder: (context, day, focusedDay) =>
              _buildCalendarCell(day, true, colors),
        ),
      ),
    );
  }

  Widget _buildCalendarCell(
      DateTime date, bool isSelected, ColorScheme colors) {
    final normalizedDate = DateTime(date.year, date.month, date.day);
    final hasRecord = _attendanceRecords.containsKey(normalizedDate);

    return Container(
      margin: const EdgeInsets.all(6.0),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: hasRecord
            ? (isSelected
            ? colors.primary
            : colors.primaryContainer.withOpacity(0.4))
            : (isSelected ? colors.outlineVariant : Colors.transparent),
        shape: BoxShape.circle,
      ),
      child: Text(
        '${date.day}',
        style: TextStyle(
          color: isSelected
              ? colors.onPrimary
              : (hasRecord ? colors.onSurface : colors.onSurfaceVariant),
          fontWeight:
          isSelected || hasRecord ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
  }

  Widget _buildSelectedDayDetailCard(ColorScheme colors) {
    final normalizedDate =
    DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
    final record = _attendanceRecords[normalizedDate];

    if (record == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withOpacity(0.3),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Icon(Icons.event_busy, color: colors.outline, size: 32),
            const SizedBox(height: 8),
            Text(
              "No records for ${DateFormat('MMMM d, yyyy').format(_selectedDate)}",
              style: TextStyle(color: colors.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    final String rawDate = record['date']?.toString() ?? '';
    final String timeIn = _convertToPhTime(rawDate, record['timeIn']);
    final String timeOut = _convertToPhTime(rawDate, record['timeOut']);
    final String timeInImg = record['timeInImage'] ?? '';
    final String timeOutImg = record['timeOutImage'] ?? '';
    final double hours = (record['totalHours'] ?? 0).toDouble();

    // Safely parse lat/lng
    double? lat = double.tryParse(record['latitude']?.toString() ?? '');
    double? lng = double.tryParse(record['longitude']?.toString() ?? '');

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant.withOpacity(0.6)),
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                DateFormat('EEEE, MMM d').format(_selectedDate),
                style:
                const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  "${hours.toStringAsFixed(1)} hrs",
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: colors.onPrimaryContainer),
                ),
              ),
            ],
          ),
          const Divider(height: 24),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildTimeLogColumn(
                  "TIME IN", timeIn, timeInImg, Colors.green, colors),
              Container(
                  width: 1,
                  height: 100,
                  color: colors.outlineVariant.withOpacity(0.5),
                  margin: const EdgeInsets.symmetric(horizontal: 16)),
              _buildTimeLogColumn(
                  "TIME OUT", timeOut, timeOutImg, Colors.red, colors),
            ],
          ),
          const SizedBox(height: 16),
          if (lat != null && lng != null && lat != 0.0 && lng != 0.0)
            Row(
              children: [
                Icon(Icons.location_on, size: 16, color: colors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: FutureBuilder<String>(
                    future: _fetchAddress(lat, lng),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return Text(
                          "Getting street address...",
                          style: TextStyle(
                              fontSize: 12, color: colors.onSurfaceVariant),
                        );
                      }
                      return Text(
                        snapshot.data ?? "Unknown Location",
                        style: TextStyle(
                            fontSize: 12, color: colors.onSurfaceVariant),
                      );
                    },
                  ),
                ),
              ],
            )
        ],
      ),
    );
  }

  Widget _buildTimeLogColumn(String label, String time, String imgUrl,
      Color iconColor, ColorScheme colors) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(label.contains("IN") ? Icons.login : Icons.logout,
                  size: 16, color: iconColor),
              const SizedBox(width: 4),
              Text(label,
                  style: TextStyle(
                      fontSize: 11,
                      color: colors.onSurfaceVariant,
                      fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 4),
          Text(time,
              style:
              const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (imgUrl.isNotEmpty && imgUrl.startsWith('http'))
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                imgUrl,
                height: 60,
                width: 60,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => Container(
                  height: 60,
                  width: 60,
                  color: colors.surfaceContainerHighest,
                  child: Icon(Icons.broken_image,
                      color: colors.outline, size: 20),
                ),
              ),
            )
          else
            Container(
              height: 60,
              width: 60,
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest.withOpacity(0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.image_not_supported,
                  color: colors.outline, size: 20),
            ),
        ],
      ),
    );
  }

  Widget _buildListView(ColorScheme colors) {
    if (_attendanceRecords.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Text("No records available.",
              style: TextStyle(color: colors.onSurfaceVariant)),
        ),
      );
    }

    final sortedDates = _attendanceRecords.keys.toList()
      ..sort((a, b) => b.compareTo(a));

    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: sortedDates.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final date = sortedDates[index];
        final record = _attendanceRecords[date];

        final String rawDate = record['date']?.toString() ?? '';
        final String timeIn = _convertToPhTime(rawDate, record['timeIn']);
        final String timeOut = _convertToPhTime(rawDate, record['timeOut']);

        return Card(
          elevation: 0,
          color: colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: colors.outlineVariant.withOpacity(0.5)),
          ),
          child: ListTile(
            contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: Container(
              width: 50,
              decoration: BoxDecoration(
                color: colors.primaryContainer.withOpacity(0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text("${date.day}",
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: colors.onPrimaryContainer,
                          fontSize: 16)),
                  Text(DateFormat('EEE').format(date),
                      style: TextStyle(
                          fontSize: 10, color: colors.onPrimaryContainer)),
                ],
              ),
            ),
            title: Text(
              "In: $timeIn  |  Out: $timeOut",
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              "Total: ${record['totalHours']} hrs",
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
            trailing: Icon(Icons.chevron_right, color: colors.outline),
            onTap: () {
              setState(() {
                _selectedDate = date;
                _focusedMonth = date;
                _isCalendarView = true;
              });
            },
          ),
        );
      },
    );
  }
}