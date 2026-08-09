import 'package:dtrsync/features/admin/screens/user_monthly_attendance_screen.dart';
import 'package:flutter/material.dart';
import 'package:dtrsync/core/network/api_client.dart';

// ===========================================================================
// LIST USERS SCREEN
// ===========================================================================

class ListUserAttendance extends StatefulWidget {
  const ListUserAttendance({super.key});

  @override
  State<ListUserAttendance> createState() => _ListUserAttendanceState();
}

class _ListUserAttendanceState extends State<ListUserAttendance> {
  List<dynamic> _allUsers = [];
  List<dynamic> _filteredUsers = [];
  bool _isLoadingUsers = true;

  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fetchUsers();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Pull-to-refresh handler
  Future<void> _onRefresh() async {
    await _fetchUsers();
  }

  /// GET /v1/users
  Future<void> _fetchUsers() async {
    setState(() {
      _isLoadingUsers = true;
    });

    try {
      final response = await ApiClient.dio.get('/v1/users');
      if (response.statusCode == 200 && response.data != null) {
        // Filter out ADMIN users from the list
        final List<dynamic> allFetchedUsers = response.data;
        final nonAdminUsers = allFetchedUsers.where((user) => user['role'] != 'ADMIN').toList();

        if (mounted) {
          setState(() {
            _allUsers = nonAdminUsers;
            _isLoadingUsers = false;
          });
          // Re-apply filter if there's an active search during refresh
          _runFilter(_searchController.text);
        }
      }
    } catch (e) {
      debugPrint("Error fetching users: $e");
      if (mounted) {
        setState(() => _isLoadingUsers = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Failed to load users: $e")),
        );
      }
    }
  }

  /// Filter users based on search query
  void _runFilter(String enteredKeyword) {
    List<dynamic> results = [];
    if (enteredKeyword.isEmpty) {
      results = _allUsers;
    } else {
      results = _allUsers.where((user) {
        final firstName = (user['firstName'] ?? '').toString().toLowerCase();
        final lastName = (user['lastName'] ?? '').toString().toLowerCase();
        final email = (user['email'] ?? '').toString().toLowerCase();
        final fullName = "$firstName $lastName".trim();
        final keyword = enteredKeyword.toLowerCase();

        return fullName.contains(keyword) || email.contains(keyword);
      }).toList();
    }

    setState(() {
      _filteredUsers = results;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: const Text("Users List"),
        elevation: 0,
        backgroundColor: colorScheme.surface,
        scrolledUnderElevation: 0,
      ),
      body: _isLoadingUsers
          ? const Center(child: CircularProgressIndicator())
          : Column(
        children: [
          // ==========================================
          // SEARCH BAR
          // ==========================================
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: TextField(
              controller: _searchController,
              onChanged: (value) => _runFilter(value),
              decoration: InputDecoration(
                hintText: 'Search by name or email...',
                hintStyle: TextStyle(color: colorScheme.onSurfaceVariant.withOpacity(0.7)),
                prefixIcon: Icon(Icons.search_rounded, color: colorScheme.primary),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                  icon: Icon(Icons.clear_rounded, color: colorScheme.onSurfaceVariant),
                  onPressed: () {
                    _searchController.clear();
                    _runFilter('');
                    // Unfocus keyboard when clearing
                    FocusScope.of(context).unfocus();
                  },
                )
                    : null,
                filled: true,
                fillColor: colorScheme.surfaceContainerHighest.withOpacity(0.3),
                contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                    color: colorScheme.outlineVariant.withOpacity(0.5),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                    color: colorScheme.outlineVariant.withOpacity(0.5),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
                ),
              ),
            ),
          ),

          // ==========================================
          // USER LIST
          // ==========================================
          Expanded(
            child: RefreshIndicator(
              onRefresh: _onRefresh,
              color: colorScheme.primary,
              child: _filteredUsers.isEmpty
                  ? _buildEmptyState(colorScheme)
                  : ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _filteredUsers.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final user = _filteredUsers[index];
                  return _buildUserCard(user, colorScheme);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme colorScheme) {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: Container(
        height: MediaQuery.of(context).size.height * 0.5,
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off_rounded, size: 80, color: colorScheme.surfaceContainerHighest),
            const SizedBox(height: 16),
            Text(
              _searchController.text.isNotEmpty
                  ? "No users match your search"
                  : "No users found",
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _searchController.text.isNotEmpty
                  ? "Try a different name or email"
                  : "Pull down to refresh",
              style: TextStyle(color: colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUserCard(dynamic user, ColorScheme colorScheme) {
    final int userId = user['id'] ?? 0;
    final String firstName = user['firstName'] ?? '';
    final String lastName = user['lastName'] ?? '';
    final String email = user['email'] ?? 'No email provided';
    final String role = user['role'] ?? 'USER';
    final String? profilePictureUrl = user['profilePictureUrl'];

    final String fullName = "$firstName $lastName".trim();
    final String displayName = fullName.isEmpty ? "User #$userId" : fullName;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colorScheme.outlineVariant.withOpacity(0.4)),
        boxShadow: [
          BoxShadow(
            color: colorScheme.shadow.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          radius: 24,
          backgroundColor: colorScheme.primaryContainer.withOpacity(0.8),
          backgroundImage: profilePictureUrl != null && profilePictureUrl.isNotEmpty
              ? NetworkImage(profilePictureUrl)
              : null,
          child: profilePictureUrl == null || profilePictureUrl.isEmpty
              ? Text(
            displayName.isNotEmpty ? displayName[0].toUpperCase() : "?",
            style: TextStyle(
              color: colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.bold,
              fontSize: 18,
            ),
          )
              : null,
        ),
        title: Text(
          displayName,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                email,
                style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: colorScheme.secondaryContainer.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  role,
                  style: TextStyle(
                    color: colorScheme.onSecondaryContainer,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
        trailing: Icon(Icons.arrow_forward_ios_rounded, size: 16, color: colorScheme.outline),
        onTap: () {
          FocusScope.of(context).unfocus();

          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => UserMonthlyAttendanceScreen(
                userId: userId,
                userName: displayName,
              ),
            ),
          );
        },
      ),
    );
  }
}