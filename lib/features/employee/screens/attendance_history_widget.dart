import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:dio/dio.dart';

import 'package:dtrsync/core/network/api_client.dart';
import 'package:dtrsync/core/storage/token_storage.dart';

class AttendanceHistoryWidget extends StatefulWidget {
  const AttendanceHistoryWidget({super.key});

  @override
  State<AttendanceHistoryWidget> createState() => _AttendanceHistoryWidgetState();
}

class _AttendanceHistoryWidgetState extends State<AttendanceHistoryWidget> {
  List<dynamic> _recentHistory = [];
  bool _isLoading = true;
  String? _userId;

  @override
  void initState() {
    super.initState();
    _loadRecentHistory();
  }

  Future<void> _loadRecentHistory() async {
    setState(() => _isLoading = true);

    try {
      _userId = await TokenStorage.getUserId();
      if (_userId == null) throw Exception("User ID not found");

      // The endpoint returning the new AttendanceResponse DTO list
      final response = await ApiClient.dio.get("/v1/attendances/user/$_userId/recent");

      if (!mounted) return;
      setState(() {
        _recentHistory = response.data ?? [];
      });
    } on DioException catch (e) {
      debugPrint("Dio error: ${e.message}");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Failed to load history: ${e.message}")),
        );
      }
    } catch (e) {
      debugPrint("Error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // Helper method to convert UTC Date and Time to Philippine Time (UTC+8)
  String _formatTime(String? dateStr, String? timeStr) {
    if (timeStr == null || timeStr.isEmpty || timeStr == "--:--") return "--:--";

    try {
      DateTime parsedUtc;

      if (dateStr != null && dateStr.isNotEmpty) {
        // Extract just the date part if it contains a timestamp
        String shortDate = dateStr.contains('T') ? dateStr.split('T')[0] : dateStr;
        // Append Z to enforce UTC parsing
        parsedUtc = DateTime.parse('${shortDate}T$timeStr${timeStr.length == 5 ? ':00' : ''}Z').toUtc();
      } else {
        // Fallback if date is missing
        parsedUtc = DateTime.parse('1970-01-01T$timeStr${timeStr.length == 5 ? ':00' : ''}Z').toUtc();
      }

      // Convert to Philippine Time (UTC+8)
      final phTime = parsedUtc.add(const Duration(hours: 8));
      return DateFormat("h:mm a").format(phTime);
    } catch (e) {
      debugPrint("Error parsing time: $e");
      return timeStr; // Fallback if parsing fails
    }
  }

  // Helper method to parse the date string from backend
  String _formatDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return "Unknown Date";
    try {
      // Ensure we only parse the date portion so it doesn't accidentally shift timezones
      String shortDate = dateStr.contains('T') ? dateStr.split('T')[0] : dateStr;
      final dt = DateTime.parse(shortDate);
      return DateFormat('EEEE, MMM dd, yyyy').format(dt);
    } catch (e) {
      return dateStr; // Fallback if parsing fails
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min, // Takes up only needed height
      children: [
        // ==========================================
        // HEADER ROW (Title + Refresh Button)
        // ==========================================
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              "Recent History",
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
            ),
            IconButton(
              icon: Icon(Icons.refresh_rounded, color: colorScheme.primary, size: 20),
              onPressed: _loadRecentHistory,
              tooltip: "Refresh History",
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // ==========================================
        // LIST SECTION
        // ==========================================
        _buildHistoryList(colorScheme),
      ],
    );
  }

  Widget _buildHistoryList(ColorScheme colorScheme) {
    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_recentHistory.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Text(
            "No recent attendance records",
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true, // Crucial for using inside a parent ScrollView
      physics: const NeverScrollableScrollPhysics(), // Let the parent handle scrolling
      itemCount: _recentHistory.length,
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final item = _recentHistory[index];
        final rawDate = item["date"]?.toString();

        final displayDate = _formatDate(rawDate);
        // Pass both the date and time strings so the UTC parser knows exactly when this occurred
        final timeInStr = _formatTime(rawDate, item["timeIn"]?.toString());
        final timeOutStr = _formatTime(rawDate, item["timeOut"]?.toString());

        final totalHours = item["totalHours"] ?? 0;
        final timeInImage = item["timeInImage"];
        final timeOutImage = item["timeOutImage"];

        return Card(
          elevation: 0,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: colorScheme.outlineVariant.withOpacity(0.4)),
          ),
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),

              // ==========================================
              // COLLAPSED HEADER
              // ==========================================
              title: Row(
                children: [
                  Icon(Icons.calendar_today_rounded, size: 16, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    displayDate,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.primary,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 16.0),
                child: Row(
                  children: [
                    Expanded(
                      child: _buildPunchColumn(
                        title: "TIME IN",
                        timeStr: timeInStr,
                        icon: Icons.login_rounded,
                        color: Colors.green,
                        colorScheme: colorScheme,
                      ),
                    ),
                    Container(
                      width: 1,
                      height: 30,
                      color: colorScheme.outlineVariant.withOpacity(0.4),
                    ),
                    Expanded(
                      child: _buildPunchColumn(
                        title: "TIME OUT",
                        timeStr: timeOutStr,
                        icon: Icons.logout_rounded,
                        color: Colors.amber.shade800,
                        colorScheme: colorScheme,
                      ),
                    ),
                  ],
                ),
              ),

              // ==========================================
              // EXPANDED CONTENT
              // ==========================================
              children: [
                Divider(color: colorScheme.outlineVariant.withOpacity(0.4)),
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: colorScheme.secondaryContainer.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Center(
                          child: Text(
                            "Total Hours: $totalHours",
                            style: TextStyle(
                              color: colorScheme.onSecondaryContainer,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _buildImageSection(
                              "Time In Photo",
                              timeInImage,
                              colorScheme,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: _buildImageSection(
                              "Time Out Photo",
                              timeOutImage,
                              colorScheme,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPunchColumn({
    required String title,
    required String timeStr,
    required IconData icon,
    required Color color,
    required ColorScheme colorScheme,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              title,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurfaceVariant,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          timeStr,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: timeStr == "--:--"
                ? colorScheme.onSurface.withOpacity(0.3)
                : colorScheme.onSurface,
          ),
        ),
      ],
    );
  }

  Widget _buildImageSection(String label, String? imageUrl, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          height: 100,
          width: double.infinity,
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colorScheme.outlineVariant.withOpacity(0.5)),
          ),
          child: imageUrl != null && imageUrl.isNotEmpty
              ? ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(
              imageUrl,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => const Icon(
                  Icons.broken_image_rounded,
                  color: Colors.grey
              ),
            ),
          )
              : Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                  Icons.image_not_supported_rounded,
                  color: colorScheme.onSurfaceVariant.withOpacity(0.5)
              ),
              const SizedBox(height: 4),
              Text(
                "No Photo",
                style: TextStyle(fontSize: 10, color: colorScheme.onSurfaceVariant),
              )
            ],
          ),
        ),
      ],
    );
  }
}