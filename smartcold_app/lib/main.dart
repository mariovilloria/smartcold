import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import 'widgets/operation_progress_dialog.dart';
import 'firebase_options.dart';
import 'services/backend_service.dart';
import 'services/local_esp_service.dart';
import 'services/smartcold_connection_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  static const String deviceId = 'SmartCold-2CBB74C55494';

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SmartCold',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        fontFamily: 'Roboto',
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00A8FF),
          brightness: Brightness.dark,
        ),
      ),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  static const String deviceId = MyApp.deviceId;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnapshot) {
        if (authSnapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: Color(0xFF020B14),
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final user = authSnapshot.data;
        debugPrint('AUTH UID: ${user?.uid}');
        debugPrint('AUTH EMAIL: ${user?.email}');
        if (user == null) {
          return const LoginPage();
        }

        return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          future: FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .get(),
          builder: (context, userSnapshot) {
            if (userSnapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                backgroundColor: Color(0xFF020B14),
                body: Center(child: CircularProgressIndicator()),
              );
            }
            debugPrint('USER DOC EXISTS: ${userSnapshot.data?.exists}');
            debugPrint('USER DOC DATA: ${userSnapshot.data?.data()}');
            if (!userSnapshot.hasData || !userSnapshot.data!.exists) {
              return const AccessDeniedPage(message: 'Usuario no autorizado.');
            }

            final userData = userSnapshot.data!.data() ?? {};
            final active = userData['active'] == true;

            if (!active) {
              return const AccessDeniedPage(message: 'Usuario inactivo.');
            }

            if (userData['must_change_password'] == true) {
              return const ForcePasswordChangePage();
            }

            return DevicesPage(userData: userData);
          },
        );
      },
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class ForcePasswordChangePage extends StatefulWidget {
  const ForcePasswordChangePage({super.key});

  @override
  State<ForcePasswordChangePage> createState() =>
      _ForcePasswordChangePageState();
}

class _ForcePasswordChangePageState extends State<ForcePasswordChangePage> {
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _changePassword() async {
    final user = FirebaseAuth.instance.currentUser;
    final newPassword = _newPasswordController.text.trim();
    final confirmPassword = _confirmPasswordController.text.trim();

    if (user == null) return;

    if (newPassword.length < 8) {
      setState(() {
        _error = 'La nueva clave debe tener al menos 8 caracteres.';
      });
      return;
    }

    if (newPassword != confirmPassword) {
      setState(() {
        _error = 'Las claves no coinciden.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await user.updatePassword(newPassword);

      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .update({
            'must_change_password': false,
            'temporary_password_used': false,
            'password_changed_at': DateTime.now().toIso8601String(),
            'updated_at': DateTime.now().toIso8601String(),
          });

      await FirebaseAuth.instance.signOut();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = 'Error cambiando clave: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF020B14),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(22),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Card(
                color: const Color(0xFF061A2E),
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.lock_reset_rounded,
                        color: Color(0xFF00A8FF),
                        size: 54,
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'Cambiar clave temporal',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Por seguridad debes crear una nueva clave antes de usar SmartCold.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Color(0xFF9DB0C1),
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: _newPasswordController,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Nueva clave',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _confirmPasswordController,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Confirmar nueva clave',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.redAccent),
                        ),
                      ],
                      const SizedBox(height: 18),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _loading ? null : _changePassword,
                          icon: _loading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.check_rounded),
                          label: Text(
                            _loading ? 'Guardando...' : 'Cambiar clave',
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextButton.icon(
                        onPressed: _loading
                            ? null
                            : () async {
                                await FirebaseAuth.instance.signOut();
                              },
                        icon: const Icon(Icons.logout_rounded),
                        label: const Text('Cerrar sesión'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AccessDeniedPage extends StatelessWidget {
  const AccessDeniedPage({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF020B14),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_rounded, color: Colors.redAccent, size: 54),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 18),
              ElevatedButton.icon(
                onPressed: () async {
                  await FirebaseAuth.instance.signOut();
                },
                icon: const Icon(Icons.logout_rounded),
                label: const Text('Cerrar sesión'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key, required this.userData});

  final Map<String, dynamic> userData;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  String? _selectedClientId;
  String? _selectedStoreId;

  @override
  Widget build(BuildContext context) {
    final role = widget.userData['role']?.toString() ?? 'client';
    final clientId = widget.userData['client_id']?.toString();

    Query<Map<String, dynamic>> devicesQuery = FirebaseFirestore.instance
        .collection('devices')
        .where('active', isEqualTo: true);

    final isAdmin = role == 'admin';
    final isClient = role == 'client';
    final isTechnician = role == 'technician';

    if (isClient || isTechnician) {
      if (clientId == null || clientId.isEmpty) {
        return const AccessDeniedPage(
          message: 'Este usuario no tiene cliente personal asociado.',
        );
      }

      devicesQuery = devicesQuery.where(
        'current_client_id',
        isEqualTo: clientId,
      );
    }

    if (isAdmin && _selectedClientId != null) {
      devicesQuery = devicesQuery.where(
        'current_client_id',
        isEqualTo: _selectedClientId,
      );
    }

    if (isAdmin && _selectedStoreId != null) {
      devicesQuery = devicesQuery.where(
        'current_store_id',
        isEqualTo: _selectedStoreId,
      );
    }
    return Scaffold(
      backgroundColor: const Color(0xFF020B14),
      body: SafeArea(
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: devicesQuery.snapshots(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Error cargando equipos:\n${snapshot.error}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              );
            }

            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            final devices = snapshot.data!.docs;

            final clientFilter = role == 'admin'
                ? _ClientFilterSelector(
                    selectedClientId: _selectedClientId,
                    onChanged: (value) {
                      setState(() {
                        _selectedClientId = value;
                        _selectedStoreId = null;
                      });
                    },
                  )
                : const SizedBox.shrink();
            final storeFilter = role == 'admin'
                ? _StoreFilterSelector(
                    selectedStoreId: _selectedStoreId,
                    selectedClientId: _selectedClientId,
                    onChanged: (value) async {
                      if (value == null) {
                        setState(() {
                          _selectedStoreId = null;
                        });
                        return;
                      }

                      final storeDoc = await FirebaseFirestore.instance
                          .collection('stores')
                          .doc(value)
                          .get();

                      final storeData = storeDoc.data();
                      final storeClientId = storeData?['client_id']?.toString();

                      setState(() {
                        _selectedStoreId = value;

                        if (storeClientId != null && storeClientId.isNotEmpty) {
                          _selectedClientId = storeClientId;
                        }
                      });
                    },
                  )
                : const SizedBox.shrink();
            if (devices.isEmpty) {
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _DevicesHeader(totalDevices: 0, role: role),
                  clientFilter,
                  storeFilter,
                  const SizedBox(height: 18),
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.only(top: 40),
                      child: Text(
                        'No hay equipos asociados todavía.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Color(0xFF9DB0C1),
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            }

            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _DevicesHeader(totalDevices: devices.length, role: role),
                clientFilter,
                storeFilter,
                const SizedBox(height: 16),

                ...devices.map((doc) {
                  final deviceData = doc.data();

                  return _DeviceSummaryCard(
                    deviceId: doc.id,
                    deviceData: deviceData,
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => DeviceStatusPage(deviceId: doc.id),
                        ),
                      );
                    },
                  );
                }),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ClientFilterSelector extends StatelessWidget {
  const _ClientFilterSelector({
    required this.selectedClientId,
    required this.onChanged,
  });

  final String? selectedClientId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    if (selectedClientId == null) {
      return _FilterPickerTile(
        icon: Icons.business_rounded,
        label: 'Cliente',
        valueText: 'Todos los clientes',
        onTap: () async {
          final selected = await showModalBottomSheet<String?>(
            context: context,
            isScrollControlled: true,
            backgroundColor: const Color(0xFF020B14),
            builder: (context) {
              return _ClientSearchSheet(selectedClientId: selectedClientId);
            },
          );

          onChanged(selected);
        },
      );
    }

    final clientRef = FirebaseFirestore.instance
        .collection('clients')
        .doc(selectedClientId);

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: clientRef.snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data();
        final clientName = data?['name']?.toString() ?? 'Cliente seleccionado';

        return _FilterPickerTile(
          icon: Icons.business_rounded,
          label: 'Cliente',
          valueText: clientName,
          onTap: () async {
            final selected = await showModalBottomSheet<String?>(
              context: context,
              isScrollControlled: true,
              backgroundColor: const Color(0xFF020B14),
              builder: (context) {
                return _ClientSearchSheet(selectedClientId: selectedClientId);
              },
            );

            onChanged(selected);
          },
        );
      },
    );
  }
}

class _FilterPickerTile extends StatelessWidget {
  const _FilterPickerTile({
    required this.icon,
    required this.label,
    required this.valueText,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String valueText;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF061A2E),
      margin: const EdgeInsets.only(top: 12),
      child: ListTile(
        onTap: onTap,
        leading: Icon(icon, color: const Color(0xFF00A8FF)),
        title: Text(label, style: const TextStyle(color: Color(0xFF9DB0C1))),
        subtitle: Text(
          valueText,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
          ),
        ),
        trailing: const Icon(
          Icons.keyboard_arrow_down_rounded,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _ClientSearchSheet extends StatefulWidget {
  const _ClientSearchSheet({required this.selectedClientId});

  final String? selectedClientId;

  @override
  State<_ClientSearchSheet> createState() => _ClientSearchSheetState();
}

class _ClientSearchSheetState extends State<_ClientSearchSheet> {
  String _searchText = '';

  @override
  Widget build(BuildContext context) {
    final clientsQuery = FirebaseFirestore.instance
        .collection('clients')
        .where('active', isEqualTo: true);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: clientsQuery.snapshots(),
          builder: (context, snapshot) {
            final clients = snapshot.data?.docs ?? [];

            final filteredClients = clients.where((doc) {
              final data = doc.data();
              final name = data['name']?.toString().toLowerCase() ?? '';
              return name.contains(_searchText.toLowerCase());
            }).toList();

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Seleccionar cliente',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  onChanged: (value) {
                    setState(() {
                      _searchText = value.trim();
                    });
                  },
                  decoration: const InputDecoration(
                    hintText: 'Buscar cliente...',
                    prefixIcon: Icon(Icons.search_rounded),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      ListTile(
                        leading: Icon(
                          widget.selectedClientId == null
                              ? Icons.check_circle_rounded
                              : Icons.all_inclusive_rounded,
                          color: const Color(0xFF00A8FF),
                        ),
                        title: const Text(
                          'Todos los clientes',
                          style: TextStyle(color: Colors.white),
                        ),
                        onTap: () {
                          Navigator.pop(context, null);
                        },
                      ),
                      ...filteredClients.map((doc) {
                        final data = doc.data();
                        final name =
                            data['name']?.toString() ?? 'Cliente sin nombre';

                        return ListTile(
                          leading: Icon(
                            doc.id == widget.selectedClientId
                                ? Icons.check_circle_rounded
                                : Icons.business_rounded,
                            color: const Color(0xFF00A8FF),
                          ),
                          title: Text(
                            name,
                            style: const TextStyle(color: Colors.white),
                          ),
                          onTap: () {
                            Navigator.pop(context, doc.id);
                          },
                        );
                      }),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _StoreFilterSelector extends StatelessWidget {
  const _StoreFilterSelector({
    required this.selectedStoreId,
    required this.selectedClientId,
    required this.onChanged,
  });

  final String? selectedStoreId;
  final String? selectedClientId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    if (selectedStoreId == null) {
      return _FilterPickerTile(
        icon: Icons.storefront_rounded,
        label: 'Local',
        valueText: 'Todos los locales',
        onTap: () async {
          final selected = await showModalBottomSheet<String?>(
            context: context,
            isScrollControlled: true,
            backgroundColor: const Color(0xFF020B14),
            builder: (context) {
              return _StoreSearchSheet(
                selectedStoreId: selectedStoreId,
                selectedClientId: selectedClientId,
              );
            },
          );

          onChanged(selected);
        },
      );
    }

    final storeRef = FirebaseFirestore.instance
        .collection('stores')
        .doc(selectedStoreId);

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: storeRef.snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data();
        final storeName = data?['name']?.toString() ?? 'Local seleccionado';

        return _FilterPickerTile(
          icon: Icons.storefront_rounded,
          label: 'Local',
          valueText: storeName,
          onTap: () async {
            final selected = await showModalBottomSheet<String?>(
              context: context,
              isScrollControlled: true,
              backgroundColor: const Color(0xFF020B14),
              builder: (context) {
                return _StoreSearchSheet(
                  selectedStoreId: selectedStoreId,
                  selectedClientId: selectedClientId,
                );
              },
            );

            onChanged(selected);
          },
        );
      },
    );
  }
}

class _StoreSearchSheet extends StatefulWidget {
  const _StoreSearchSheet({
    required this.selectedStoreId,
    required this.selectedClientId,
  });

  final String? selectedStoreId;
  final String? selectedClientId;

  @override
  State<_StoreSearchSheet> createState() => _StoreSearchSheetState();
}

class _StoreSearchSheetState extends State<_StoreSearchSheet> {
  String _searchText = '';

  @override
  Widget build(BuildContext context) {
    Query<Map<String, dynamic>> storesQuery = FirebaseFirestore.instance
        .collection('stores')
        .where('active', isEqualTo: true);

    if (widget.selectedClientId != null) {
      storesQuery = storesQuery.where(
        'client_id',
        isEqualTo: widget.selectedClientId,
      );
    }

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: storesQuery.snapshots(),
          builder: (context, snapshot) {
            final stores = snapshot.data?.docs ?? [];

            final filteredStores = stores.where((doc) {
              final data = doc.data();
              final name = data['name']?.toString().toLowerCase() ?? '';
              return name.contains(_searchText.toLowerCase());
            }).toList();

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Seleccionar local',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  onChanged: (value) {
                    setState(() {
                      _searchText = value.trim();
                    });
                  },
                  decoration: const InputDecoration(
                    hintText: 'Buscar local...',
                    prefixIcon: Icon(Icons.search_rounded),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      ListTile(
                        leading: Icon(
                          widget.selectedStoreId == null
                              ? Icons.check_circle_rounded
                              : Icons.all_inclusive_rounded,
                          color: const Color(0xFF00A8FF),
                        ),
                        title: const Text(
                          'Todos los locales',
                          style: TextStyle(color: Colors.white),
                        ),
                        onTap: () {
                          Navigator.pop(context, null);
                        },
                      ),
                      ...filteredStores.map((doc) {
                        final data = doc.data();
                        final name =
                            data['name']?.toString() ?? 'Local sin nombre';

                        return ListTile(
                          leading: Icon(
                            doc.id == widget.selectedStoreId
                                ? Icons.check_circle_rounded
                                : Icons.storefront_rounded,
                            color: const Color(0xFF00A8FF),
                          ),
                          title: Text(
                            name,
                            style: const TextStyle(color: Colors.white),
                          ),
                          onTap: () {
                            Navigator.pop(context, doc.id);
                          },
                        );
                      }),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _DevicesHeader extends StatelessWidget {
  const _DevicesHeader({required this.totalDevices, required this.role});

  final int totalDevices;
  final String role;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          colors: [Color(0xFF061A2E), Color(0xFF082B49)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: const Color(0xFF00A8FF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.ac_unit_rounded,
                color: Color(0xFF00A8FF),
                size: 34,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  role == 'admin' ? 'Equipos' : 'Mis equipos',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 25,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.menu_rounded, color: Color(0xFF9DB0C1)),
                color: const Color(0xFF061A2E),
                onSelected: (value) async {
                  if (value == 'new_installation') {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const NewInstallationPage(),
                      ),
                    );
                    return;
                  }
                  if (value == 'clients') {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ClientsPage()),
                    );
                    return;
                  }
                  if (value == 'account') {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const AccountPage()),
                    );
                    return;
                  }

                  if (value == 'logout') {
                    final confirmar = await showDialog<bool>(
                      context: context,
                      builder: (context) {
                        return AlertDialog(
                          title: const Text('Cerrar sesión'),
                          content: const Text(
                            '¿Deseas cerrar la sesión actual?',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Cancelar'),
                            ),
                            ElevatedButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Cerrar sesión'),
                            ),
                          ],
                        );
                      },
                    );

                    if (confirmar == true) {
                      await FirebaseAuth.instance.signOut();
                    }
                  }
                },
                itemBuilder: (context) => [
                  if (role == 'admin' || role == 'technician')
                    const PopupMenuItem(
                      value: 'new_installation',
                      child: Text('Nueva instalación'),
                    ),
                  if (role == 'admin')
                    const PopupMenuItem(
                      value: 'clients',
                      child: Text('Clientes'),
                    ),
                  const PopupMenuItem(
                    value: 'account',
                    child: Text('Mi cuenta'),
                  ),
                  const PopupMenuItem(
                    value: 'logout',
                    child: Text('Cerrar sesión'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            role == 'admin'
                ? '$totalDevices equipo${totalDevices == 1 ? '' : 's'} visible${totalDevices == 1 ? '' : 's'}'
                : '$totalDevices equipo${totalDevices == 1 ? '' : 's'} asociado${totalDevices == 1 ? '' : 's'}',
            style: const TextStyle(
              color: Color(0xFFB6C7D6),
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Vista rápida del estado general de tus equipos.',
            style: TextStyle(color: Color(0xFF8DA1B2), fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class AccountPage extends StatelessWidget {
  const AccountPage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF020B14),
        body: Center(
          child: Text(
            'No hay sesión activa',
            style: TextStyle(color: Colors.white),
          ),
        ),
      );
    }

    final userRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid);

    return Scaffold(
      backgroundColor: const Color(0xFF020B14),
      body: SafeArea(
        child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: userRef.snapshots(),
          builder: (context, snapshot) {
            final data = snapshot.data?.data() ?? {};

            final email = data['email']?.toString() ?? user.email ?? '—';
            final role = data['role']?.toString() ?? '—';
            final clientId = data['client_id']?.toString() ?? '—';

            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Volver',
                      icon: const Icon(
                        Icons.arrow_back_rounded,
                        color: Colors.white,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Mi cuenta',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 25,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _AccountInfoTile(
                  icon: Icons.email_rounded,
                  title: 'Correo',
                  value: email,
                ),
                _AccountInfoTile(
                  icon: Icons.verified_user_rounded,
                  title: 'Rol',
                  value: role,
                ),
                _AccountInfoTile(
                  icon: Icons.business_rounded,
                  title: 'Cliente asociado',
                  value: clientId,
                ),
                const SizedBox(height: 18),
                ElevatedButton.icon(
                  onPressed: () async {
                    if (user.email == null) return;

                    await FirebaseAuth.instance.sendPasswordResetEmail(
                      email: user.email!,
                    );

                    if (!context.mounted) return;

                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Te enviamos un correo para cambiar tu contraseña',
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.lock_reset_rounded),
                  label: const Text('Cambiar contraseña'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _AccountInfoTile extends StatelessWidget {
  const _AccountInfoTile({
    required this.icon,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF061A2E),
      child: ListTile(
        leading: Icon(icon, color: const Color(0xFF00A8FF)),
        title: Text(title, style: const TextStyle(color: Color(0xFF9DB0C1))),
        subtitle: Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _DeviceSummaryCard extends StatelessWidget {
  const _DeviceSummaryCard({
    required this.deviceId,
    required this.deviceData,
    required this.onTap,
  });

  final String deviceId;
  final Map<String, dynamic> deviceData;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final statusRef = FirebaseFirestore.instance
        .collection('device_status')
        .doc(deviceId);

    final name = deviceData['name']?.toString() ?? deviceId;
    final equipmentType =
        deviceData['equipment_type']?.toString() ?? 'refrigerator';

    final type = equipmentType == 'freezer' ? 'Congelador' : 'Refrigerador';
    final assigned =
        deviceData['current_client_id'] != null &&
        deviceData['current_client_id'].toString().isNotEmpty &&
        deviceData['current_store_id'] != null &&
        deviceData['current_store_id'].toString().isNotEmpty;
    final storeName = assigned
        ? (deviceData['current_store_name']?.toString() ??
              deviceData['current_store_id']?.toString() ??
              'Tienda sin nombre')
        : 'Pendiente de asignar';

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: statusRef.snapshots(),
      builder: (context, snapshot) {
        final statusData = snapshot.data?.data();

        final state = statusData?['device_state']?.toString() ?? 'SIN DATOS';
        final health = statusData?['device_health']?.toString() ?? 'UNKNOWN';
        final rawDeviceMode = statusData?['device_mode']?.toString();
        final rawServiceMode = statusData?['service_mode'] == true;

        final serviceMode = rawServiceMode || rawDeviceMode == 'SERVICE';
        final healthReason =
            statusData?['device_health_reason']?.toString() ?? '';
        final chamberTemp = _readSensor(statusData, 'chamber');
        final seconds = _secondsSinceLastSeen(statusData?['last_seen_at']);
        final connection = _connectionStatus(seconds);

        final isOffline = connection == 'offline';
        final hasWarning = health == 'WARNING' || health == 'ERROR';
        final displayState = serviceMode ? 'MANTENIMIENTO' : _stateLabel(state);

        final color = serviceMode
            ? Colors.orangeAccent
            : isOffline
            ? Colors.redAccent
            : hasWarning
            ? Colors.orangeAccent
            : const Color(0xFF20D76D);

        return Card(
          color: const Color(0xFF061A2E),
          margin: const EdgeInsets.only(bottom: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: color.withValues(alpha: 0.85)),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(Icons.kitchen_rounded, color: color),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Local: $storeName',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Color(0xFF9DB0C1),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  type == 'refrigeration_controller'
                                      ? 'Refrigerador'
                                      : type,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xFF00A8FF),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: Colors.white,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: _SmallStatusBox(
                          label: 'Temp.',
                          value: chamberTemp == null
                              ? '—'
                              : '${chamberTemp.toStringAsFixed(1)}°C',
                          color: color,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _SmallStatusBox(
                          label: 'Estado',
                          value: displayState,
                          color: color,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _SmallStatusBox(
                          label: 'Conexión',
                          value: _connectionLabel(connection),
                          color: color,
                        ),
                      ),
                    ],
                  ),
                  if (!assigned) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  AssignDevicePage(deviceId: deviceId),
                            ),
                          );
                        },
                        icon: const Icon(Icons.link_rounded),
                        label: const Text('Asignar equipo'),
                      ),
                    ),
                  ],
                  if (hasWarning || isOffline) ...[
                    const SizedBox(height: 10),
                    Text(
                      isOffline
                          ? 'Equipo sin actualización reciente'
                          : _healthReasonLabel(healthReason),
                      style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static double? _readSensor(Map<String, dynamic>? data, String role) {
    final readings = data?['sensor_readings'];
    if (readings is Map && readings[role] is num) {
      return (readings[role] as num).toDouble();
    }
    return null;
  }

  static int? _secondsSinceLastSeen(dynamic value) {
    if (value == null) return null;

    DateTime? lastSeenUtc;

    if (value is Timestamp) {
      lastSeenUtc = value.toDate().toUtc();
    } else if (value is String) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) {
        lastSeenUtc = DateTime.utc(
          parsed.year,
          parsed.month,
          parsed.day,
          parsed.hour,
          parsed.minute,
          parsed.second,
          parsed.millisecond,
          parsed.microsecond,
        );
      }
    }

    if (lastSeenUtc == null) return null;

    final seconds = DateTime.now().toUtc().difference(lastSeenUtc).inSeconds;
    return seconds < 0 ? 0 : seconds;
  }

  static String _connectionStatus(int? seconds) {
    if (seconds == null) return 'offline';
    if (seconds <= 30) return 'online';
    if (seconds <= 90) return 'warning';
    return 'offline';
  }

  static String _connectionLabel(String value) {
    if (value == 'online') return 'ONLINE';
    if (value == 'warning') return 'LENTO';
    return 'OFFLINE';
  }

  static String _stateLabel(String value) {
    if (value == 'COOLING') return 'ENFRÍA';
    if (value == 'PROTECTION') return 'PROT.';
    if (value == 'DEFROST') return 'DEFROST';
    if (value == 'DRIP') return 'GOTEO';
    if (value == 'IDLE') return 'ESPERA';
    return '—';
  }

  static String _healthReasonLabel(String value) {
    if (value == 'HIGH_TEMP') return 'Alerta: temperatura alta';
    if (value == 'LOW_TEMP') return 'Alerta: temperatura baja';
    if (value == 'SENSOR_ERROR') return 'Alerta: falla de sensor';
    return 'Equipo con alerta';
  }
}

class _SmallStatusBox extends StatelessWidget {
  const _SmallStatusBox({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF020B14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF8DA1B2),
              fontSize: 10,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _LoginPageState extends State<LoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      setState(() {
        _error = 'Ingresa correo y contraseña';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
    } on FirebaseAuthException catch (e) {
      setState(() {
        _error = e.message ?? 'No se pudo iniciar sesión';
      });
    } catch (_) {
      setState(() {
        _error = 'Error inesperado iniciando sesión';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF020B14),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(22),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: const Color(0xFF061A2E),
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(color: const Color(0xFF00A8FF)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.ac_unit_rounded,
                      color: Color(0xFF00A8FF),
                      size: 54,
                    ),
                    const SizedBox(height: 12),
                    const Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: 'SMART',
                            style: TextStyle(color: Colors.white),
                          ),
                          TextSpan(
                            text: 'COLD',
                            style: TextStyle(color: Color(0xFF00A8FF)),
                          ),
                        ],
                      ),
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Correo',
                        prefixIcon: Icon(Icons.email_rounded),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _passwordController,
                      obscureText: true,
                      onSubmitted: (_) => _login(),
                      decoration: const InputDecoration(
                        labelText: 'Contraseña',
                        prefixIcon: Icon(Icons.lock_rounded),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ],
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton.icon(
                        onPressed: _loading ? null : _login,
                        icon: _loading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.login_rounded),
                        label: Text(
                          _loading ? 'Ingresando...' : 'Iniciar sesión',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AssignDevicePage extends StatefulWidget {
  const AssignDevicePage({super.key, required this.deviceId});

  final String deviceId;

  @override
  State<AssignDevicePage> createState() => _AssignDevicePageState();
}

class _AssignDevicePageState extends State<AssignDevicePage> {
  String? _selectedClientId;
  String? _selectedStoreId;

  final _deviceNameController = TextEditingController();

  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _deviceNameController.dispose();
    super.dispose();
  }

  Future<void> _assignDevice() async {
    final deviceName = _deviceNameController.text.trim();

    if (_selectedClientId == null || _selectedStoreId == null) {
      setState(() {
        _error = 'Selecciona cliente y local.';
      });
      return;
    }

    if (deviceName.isEmpty) {
      setState(() {
        _error = 'Ingresa el nombre del equipo.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

      final response = await http.post(
        Uri.parse(
          'https://smartcold-api-649501100610.us-central1.run.app/api/devices/${widget.deviceId}/assign',
        ),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'client_id': _selectedClientId,
          'store_id': _selectedStoreId,
          'device_name': deviceName,
          'assigned_by': uid,
        }),
      );

      final body = jsonDecode(response.body);

      if (response.statusCode != 200 || body['success'] != true) {
        throw Exception(body['message'] ?? 'No se pudo asignar el equipo');
      }

      if (!mounted) return;

      await showDialog<void>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Equipo asignado'),
            content: Text(
              'El equipo "${widget.deviceId}" fue asignado correctamente.',
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Aceptar'),
              ),
            ],
          );
        },
      );

      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = 'Error asignando equipo: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Query<Map<String, dynamic>> storesQuery = FirebaseFirestore.instance
        .collection('stores')
        .where('active', isEqualTo: true);

    if (_selectedClientId != null) {
      storesQuery = storesQuery.where(
        'client_id',
        isEqualTo: _selectedClientId,
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF020B14),
      appBar: AppBar(
        title: const Text('Asignar equipo'),
        backgroundColor: const Color(0xFF061A2E),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            widget.deviceId,
            style: const TextStyle(
              color: Color(0xFF9DB0C1),
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 14),

          _ClientFilterSelector(
            selectedClientId: _selectedClientId,
            onChanged: (value) {
              setState(() {
                _selectedClientId = value;
                _selectedStoreId = null;
              });
            },
          ),

          const SizedBox(height: 10),

          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: storesQuery.snapshots(),
            builder: (context, snapshot) {
              final stores = snapshot.data?.docs ?? [];

              return DropdownButtonFormField<String>(
                value: _selectedStoreId,
                decoration: const InputDecoration(
                  labelText: 'Local',
                  border: OutlineInputBorder(),
                ),
                dropdownColor: const Color(0xFF061A2E),
                items: stores.map((doc) {
                  final data = doc.data();
                  final name = data['name']?.toString() ?? 'Local sin nombre';

                  return DropdownMenuItem<String>(
                    value: doc.id,
                    child: Text(name),
                  );
                }).toList(),
                onChanged: _selectedClientId == null
                    ? null
                    : (value) {
                        setState(() {
                          _selectedStoreId = value;
                        });
                      },
              );
            },
          ),

          const SizedBox(height: 12),

          TextField(
            controller: _deviceNameController,
            decoration: const InputDecoration(
              labelText: 'Nombre del equipo',
              border: OutlineInputBorder(),
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],

          const SizedBox(height: 18),

          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _loading ? null : _assignDevice,
              icon: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.link_rounded),
              label: Text(_loading ? 'Asignando...' : 'Asignar equipo'),
            ),
          ),
        ],
      ),
    );
  }
}

class DeviceManagementPage extends StatefulWidget {
  const DeviceManagementPage({super.key, required this.deviceId});

  final String deviceId;

  @override
  State<DeviceManagementPage> createState() => _DeviceManagementPageState();
}

class _DeviceManagementPageState extends State<DeviceManagementPage> {
  final _nameController = TextEditingController();

  String? _selectedClientId;
  String? _selectedStoreId;
  String _equipmentType = 'refrigerator';

  bool _loading = true;
  bool _saving = false;
  String? _error;
  Map<String, dynamic> _deviceData = {};
  Map<String, dynamic> _statusData = {};

  @override
  void initState() {
    super.initState();
    _loadDevice();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadDevice() async {
    try {
      final deviceDoc = await FirebaseFirestore.instance
          .collection('devices')
          .doc(widget.deviceId)
          .get();

      final statusDoc = await FirebaseFirestore.instance
          .collection('device_status')
          .doc(widget.deviceId)
          .get();

      final data = deviceDoc.data() ?? {};
      final status = statusDoc.data() ?? {};

      _deviceData = data;
      _statusData = status;

      _nameController.text = data['name']?.toString() ?? '';
      _selectedClientId = data['current_client_id']?.toString();
      _selectedStoreId = data['current_store_id']?.toString();
      _equipmentType = data['equipment_type']?.toString() == 'freezer'
          ? 'freezer'
          : 'refrigerator';

      if (!mounted) return;

      setState(() {
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = 'Error cargando equipo: $e';
        _loading = false;
      });
    }
  }

  Future<void> _saveChanges() async {
    final deviceName = _nameController.text.trim();

    if (deviceName.isEmpty) {
      setState(() {
        _error = 'El nombre del equipo es obligatorio.';
      });
      return;
    }

    if (_selectedClientId == null || _selectedStoreId == null) {
      setState(() {
        _error = 'Selecciona cliente y local.';
      });
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Guardar cambios'),
          content: const Text(
            '¿Deseas actualizar la información administrativa de este equipo?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Guardar'),
            ),
          ],
        );
      },
    );

    if (confirm != true) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

      final response = await http.post(
        Uri.parse(
          'https://smartcold-api-649501100610.us-central1.run.app/api/devices/${widget.deviceId}/assign',
        ),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'client_id': _selectedClientId,
          'store_id': _selectedStoreId,
          'device_name': deviceName,
          'equipment_type': _equipmentType,
          'assigned_by': uid,
          'reason': 'ADMIN_UPDATE',
        }),
      );

      final body = jsonDecode(response.body);

      if (response.statusCode != 200 || body['success'] != true) {
        throw Exception(body['message'] ?? 'No se pudo actualizar el equipo');
      }

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Equipo actualizado correctamente')),
      );

      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = 'Error guardando cambios: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  String _equipmentTypeLabel(String value) {
    if (value == 'freezer') return 'Congelador';
    return 'Refrigerador';
  }

  String _onlineText() {
    if (_statusData['online'] == true) {
      return 'ONLINE';
    }

    return 'OFFLINE';
  }

  @override
  Widget build(BuildContext context) {
    Query<Map<String, dynamic>> storesQuery = FirebaseFirestore.instance
        .collection('stores')
        .where('active', isEqualTo: true);

    if (_selectedClientId != null) {
      storesQuery = storesQuery.where(
        'client_id',
        isEqualTo: _selectedClientId,
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF020B14),
      appBar: AppBar(
        title: const Text('Administrar equipo'),
        backgroundColor: const Color(0xFF061A2E),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  widget.deviceId,
                  style: const TextStyle(
                    color: Color(0xFF9DB0C1),
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 14),

                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Nombre del equipo',
                    border: OutlineInputBorder(),
                  ),
                ),

                const SizedBox(height: 14),

                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'refrigerator',
                      label: Text('Refrigerador'),
                      icon: Icon(Icons.kitchen_rounded),
                    ),
                    ButtonSegment(
                      value: 'freezer',
                      label: Text('Congelador'),
                      icon: Icon(Icons.ac_unit_rounded),
                    ),
                  ],
                  selected: {_equipmentType},
                  onSelectionChanged: (values) {
                    setState(() {
                      _equipmentType = values.first;
                    });
                  },
                ),

                const SizedBox(height: 14),

                _ClientFilterSelector(
                  selectedClientId: _selectedClientId,
                  onChanged: (value) {
                    setState(() {
                      _selectedClientId = value;
                      _selectedStoreId = null;
                    });
                  },
                ),

                const SizedBox(height: 10),

                StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: storesQuery.snapshots(),
                  builder: (context, snapshot) {
                    final stores = snapshot.data?.docs ?? [];

                    return DropdownButtonFormField<String>(
                      value: _selectedStoreId,
                      decoration: const InputDecoration(
                        labelText: 'Local',
                        border: OutlineInputBorder(),
                      ),
                      dropdownColor: const Color(0xFF061A2E),
                      items: stores.map((doc) {
                        final data = doc.data();
                        final name =
                            data['name']?.toString() ?? 'Local sin nombre';

                        return DropdownMenuItem<String>(
                          value: doc.id,
                          child: Text(name),
                        );
                      }).toList(),
                      onChanged: _selectedClientId == null
                          ? null
                          : (value) {
                              setState(() {
                                _selectedStoreId = value;
                              });
                            },
                    );
                  },
                ),

                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],

                const SizedBox(height: 18),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _saving ? null : _saveChanges,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_rounded),
                    label: Text(_saving ? 'Guardando...' : 'Guardar cambios'),
                  ),
                ),

                const SizedBox(height: 18),

                const SizedBox(height: 24),

                const Text(
                  'Información del controlador',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                  ),
                ),

                const SizedBox(height: 14),

                _AccountInfoTile(
                  icon: Icons.memory_rounded,
                  title: 'Device ID',
                  value: widget.deviceId,
                ),

                _AccountInfoTile(
                  icon: Icons.developer_board_rounded,
                  title: 'Hardware UID',
                  value: _deviceData['hardware_uid'] ?? '',
                ),

                _AccountInfoTile(
                  icon: Icons.system_update_alt_rounded,
                  title: 'Firmware',
                  value: _deviceData['firmware_version'] ?? '',
                ),

                _AccountInfoTile(
                  icon: Icons.category_rounded,
                  title: 'Tipo',
                  value: _equipmentTypeLabel(_equipmentType),
                ),

                _AccountInfoTile(
                  icon: Icons.wifi_rounded,
                  title: 'Estado',
                  value:
                      '${_onlineText()}   RSSI ${_statusData['rssi'] ?? '--'} dBm',
                ),

                _AccountInfoTile(
                  icon: Icons.schedule_rounded,
                  title: 'Última conexión',
                  value: _statusData['last_seen_at'] ?? '',
                ),

                _AccountInfoTile(
                  icon: Icons.event_available_rounded,
                  title: 'Instalado',
                  value: _deviceData['commissioned_at'] ?? '',
                ),

                _AccountInfoTile(
                  icon: Icons.person_outline_rounded,
                  title: 'Instalador',
                  value: _deviceData['installer_uid'] ?? '',
                ),
              ],
            ),
    );
  }
}

class DeviceStatusPage extends StatefulWidget {
  const DeviceStatusPage({super.key, required this.deviceId});

  final String deviceId;

  @override
  State<DeviceStatusPage> createState() => _DeviceStatusPageState();
}

class _DeviceStatusPageState extends State<DeviceStatusPage> {
  Timer? _timer;
  int? _selectedCoolingLevel;
  int? _configCoolingLevel;
  bool _configSummaryLoaded = false;
  bool _dialUnlocked = false;
  int? _levelBeforeEdit;
  double? _configSetpoint;
  double? _configTurnOnTemp;
  double? _configTurnOffTemp;
  String? _lastConfigAckSeen;
  String? _currentUserRole;
  bool _serviceModeRequestInProgress = false;
  bool? _pendingServiceModeTarget;
  Map<String, dynamic>? _localDeviceInfo;
  bool _localEspAvailable = false;
  bool _checkingLocalEsp = false;

  @override
  void initState() {
    super.initState();
    _loadConfigSummary();
    _loadCurrentUserRole();
    _refreshLocalEspInfo();

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
        _refreshLocalEspInfo();
      }
    });
  }

  Future<void> _loadCurrentUserRole() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    if (uid == null) return;

    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();

      final role = doc.data()?['role']?.toString() ?? 'client';

      if (!mounted) return;

      setState(() {
        _currentUserRole = role;
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _currentUserRole = 'client';
      });
    }
  }

  Future<void> _refreshLocalEspInfo() async {
    if (_checkingLocalEsp) return;

    _checkingLocalEsp = true;

    try {
      final info = await SmartColdConnectionManager.readLocalDeviceInfo();

      if (!mounted) return;

      setState(() {
        _localDeviceInfo = info;
        _localEspAvailable = info != null;
      });
    } finally {
      _checkingLocalEsp = false;
    }
  }

  Future<void> _requestServiceModeChange(bool targetMode) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(
            targetMode ? 'Entrar en modo servicio' : 'Salir de modo servicio',
          ),
          content: Text(
            targetMode
                ? 'Se solicitará al equipo que habilite el AP técnico. El modo servicio se activará cuando el técnico se conecte al AP.'
                : 'El equipo saldrá del modo servicio y volverá a operación normal.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirmar'),
            ),
          ],
        );
      },
    );

    if (confirm != true) return;

    setState(() {
      _serviceModeRequestInProgress = true;
      _pendingServiceModeTarget = targetMode;
    });

    try {
      // SALIR DE SERVICIO:
      // Primero intenta salida local por AP del ESP.
      if (!targetMode) {
        final localInfo =
            await SmartColdConnectionManager.readLocalDeviceInfo();

        final localExitOk = localInfo != null
            ? await LocalEspService.finishServiceMode()
            : false;

        if (localExitOk) {
          if (!mounted) return;

          setState(() {
            _serviceModeRequestInProgress = false;
            _pendingServiceModeTarget = null;
          });

          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Salida local enviada al equipo.')),
          );

          return;
        }
      }

      // ENTRAR DE SERVICIO:
      // Siempre se solicita por backend.
      // SALIR DE SERVICIO:
      // Si la salida local falló, se solicita por backend.
      await BackendService.requestServiceMode(
        deviceId: widget.deviceId,
        serviceMode: targetMode,
      );
      if (!mounted) return;

      setState(() {
        _serviceModeRequestInProgress = false;
        _pendingServiceModeTarget = null;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            targetMode
                ? 'Solicitud enviada. Conéctate al AP técnico cuando aparezca.'
                : 'Solicitud enviada. Esperando salida del modo servicio.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _serviceModeRequestInProgress = false;
        _pendingServiceModeTarget = null;
      });

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error solicitando cambio: $e')));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadConfigSummary({bool lockDial = false}) async {
    try {
      final body = await BackendService.getConfigSummary(
        deviceId: widget.deviceId,
      );

      if (!mounted) return;

      setState(() {
        _configCoolingLevel =
            _intFromDynamic(body['cooling_level']) ?? _configCoolingLevel;

        _configSetpoint =
            _doubleFromDynamic(body['setpoint']) ?? _configSetpoint;

        _configTurnOnTemp =
            _doubleFromDynamic(body['turn_on_temperature']) ??
            _configTurnOnTemp;

        _configTurnOffTemp =
            _doubleFromDynamic(body['turn_off_temperature']) ??
            _configTurnOffTemp;
        if (lockDial) {
          _selectedCoolingLevel = null;
          _levelBeforeEdit = null;
          _dialUnlocked = false;
        }
        _configSummaryLoaded = true;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _configSummaryLoaded = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusRef = FirebaseFirestore.instance
        .collection('device_status')
        .doc(widget.deviceId);
    final configRef = FirebaseFirestore.instance
        .collection('device_config')
        .doc(widget.deviceId);
    final deviceRef = FirebaseFirestore.instance
        .collection('devices')
        .doc(widget.deviceId);
    return Scaffold(
      backgroundColor: const Color(0xFF020B14),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFF020B14),
              Color(0xFF03192B),
              Color(0xFF061E32),
              Color(0xFF020B14),
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: statusRef.snapshots(),
            builder: (context, statusSnapshot) {
              if (statusSnapshot.hasError) {
                return const Center(
                  child: Text('Error leyendo estado del equipo'),
                );
              }

              if (!statusSnapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final data = statusSnapshot.data!.data();

              if (data == null) {
                return Center(
                  child: Text('No existe estado para ${widget.deviceId}'),
                );
              }
              final rawDeviceMode = data['device_mode']?.toString();
              final rawServiceMode = data['service_mode'] == true;
              final serviceModeFromStatus =
                  rawServiceMode || rawDeviceMode == 'SERVICE';
              final localDeviceMode = _localDeviceInfo?['device_mode']
                  ?.toString();
              final localServiceMode =
                  _localDeviceInfo?['service_mode'] == true;
              final serviceModeFromLocal =
                  _localEspAvailable &&
                  (localServiceMode || localDeviceMode == 'SERVICE');
              if (_currentUserRole == null) {
                return const Center(child: CircularProgressIndicator());
              }

              final canViewServiceDashboard =
                  _currentUserRole == 'admin' ||
                  _currentUserRole == 'technician';
              final lastConfigAckAt = data['last_config_ack_at']?.toString();

              if (lastConfigAckAt != null) {
                if (_lastConfigAckSeen == null) {
                  _lastConfigAckSeen = lastConfigAckAt;
                } else if (lastConfigAckAt != _lastConfigAckSeen) {
                  _lastConfigAckSeen = lastConfigAckAt;

                  WidgetsBinding.instance.addPostFrameCallback((_) async {
                    if (!mounted) return;
                    await _loadConfigSummary(lockDial: true);
                  });
                }
              }
              if (!_configSummaryLoaded) {
                return const Center(child: CircularProgressIndicator());
              }
              final savedCoolingLevel = _configCoolingLevel ?? 4;
              final visibleCoolingLevel =
                  _selectedCoolingLevel ?? savedCoolingLevel;

              final previewConfig = _coolingConfigForLevel(visibleCoolingLevel);

              final setpoint = previewConfig['setpoint']!;
              final turnOnTemp = previewConfig['turn_on_temperature']!;
              final turnOffTemp = previewConfig['turn_off_temperature']!;

              final secondsSinceLastSeen = _secondsSinceLastSeen(
                data['last_seen_at'],
              );

              final connectionStatus = _connectionStatus(secondsSinceLastSeen);

              final lastUpdateText = _lastUpdateText(secondsSinceLastSeen);

              final chamberTemp = _sensorValue(data, 'chamber');
              final evaporatorTemp = _sensorValue(data, 'evaporator');
              return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: deviceRef.snapshots(),
                builder: (context, deviceSnapshot) {
                  final deviceData = deviceSnapshot.data?.data() ?? {};

                  final deviceName =
                      deviceData['name']?.toString() ??
                      data['device_name']?.toString() ??
                      data['name']?.toString() ??
                      widget.deviceId;

                  final storeName =
                      deviceData['current_store_name']?.toString() ??
                      deviceData['store_name']?.toString() ??
                      deviceData['current_store_id']?.toString() ??
                      '';

                  return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                    stream: configRef.snapshots(),
                    builder: (context, configSnapshot) {
                      final configData = configSnapshot.data?.data() ?? {};
                      final serviceAccessStatus =
                          configData['service_access_status']?.toString() ??
                          'inactive';
                      final serviceRequestedAt =
                          configData['service_access_requested_at']?.toString();

                      final serviceRequestExpiresSeconds =
                          int.tryParse(
                            configData['service_access_request_expires_seconds']
                                    ?.toString() ??
                                '',
                          ) ??
                          300;
                      final serviceRequested =
                          serviceAccessStatus == 'requested';
                      final serviceActive =
                          serviceModeFromLocal ||
                          serviceAccessStatus == 'active' ||
                          serviceModeFromStatus;
                      final serviceExitRequested =
                          serviceAccessStatus == 'exit_requested';

                      if (serviceActive && !canViewServiceDashboard) {
                        return _ServiceModeNotice(deviceId: widget.deviceId);
                      }
                      final defrostConfig = configData['defrost'];

                      final defrostEnabled =
                          defrostConfig is Map &&
                          defrostConfig['enabled'] == true;
                      final dripTimeSeconds = defrostConfig is Map
                          ? int.tryParse(
                                  defrostConfig['drip_time_seconds']
                                          ?.toString() ??
                                      '',
                                ) ??
                                0
                          : 0;

                      final dripEnabled = defrostEnabled && dripTimeSeconds > 0;
                      return Column(
                        children: [
                          Expanded(
                            child: ListView(
                              padding: const EdgeInsets.fromLTRB(
                                16,
                                10,
                                16,
                                18,
                              ),
                              children: [
                                _TopBar(
                                  connectionStatus: connectionStatus,
                                  rssi: data['rssi'],
                                ),
                                const SizedBox(height: 14),
                                if (canViewServiceDashboard) ...[
                                  SizedBox(
                                    width: double.infinity,
                                    child: OutlinedButton.icon(
                                      onPressed: () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) =>
                                                DeviceManagementPage(
                                                  deviceId: widget.deviceId,
                                                ),
                                          ),
                                        );
                                      },
                                      icon: const Icon(Icons.settings_rounded),
                                      label: const Text('Administrar equipo'),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                ],
                                _HeroPanel(
                                  deviceName: deviceName,
                                  storeName: storeName,
                                  health: data['device_health'],
                                  healthReason: data['device_health_reason'],
                                  state: data['device_state'],
                                  online: connectionStatus != 'offline',
                                  rssi: data['rssi'],
                                  compressorOn: data['compressor_relay_on'],
                                  blockReason: data['compressor_block_reason'],
                                ),

                                const SizedBox(height: 8),
                                if (canViewServiceDashboard) ...[
                                  _ServiceToolsBanner(
                                    deviceId: widget.deviceId,
                                    serviceAccessStatus: serviceAccessStatus,
                                    serviceRequested: serviceRequested,
                                    serviceActive: serviceActive,
                                    serviceExitRequested: serviceExitRequested,
                                    serviceRequestedAt: serviceRequestedAt,
                                    serviceRequestExpiresSeconds:
                                        serviceRequestExpiresSeconds,
                                    requestInProgress:
                                        _serviceModeRequestInProgress,
                                    onToggleServiceMode:
                                        _requestServiceModeChange,
                                  ),
                                  const SizedBox(height: 12),
                                ],
                                _CoolingLevelDial(
                                  level: visibleCoolingLevel,
                                  setpoint: setpoint,
                                  turnOnTemp: turnOnTemp,
                                  turnOffTemp: turnOffTemp,
                                  unlocked: _dialUnlocked,
                                  onUnlockChanged: (value) {
                                    setState(() {
                                      if (value) {
                                        _levelBeforeEdit = visibleCoolingLevel;
                                        _dialUnlocked = true;
                                        return;
                                      }

                                      _selectedCoolingLevel = _levelBeforeEdit;
                                      _levelBeforeEdit = null;
                                      _dialUnlocked = false;
                                    });
                                  },
                                  onLevelChanged: (newLevel) {
                                    if (!_dialUnlocked) return;

                                    setState(() {
                                      _selectedCoolingLevel = newLevel;
                                    });
                                  },
                                ),

                                if (_dialUnlocked &&
                                    _selectedCoolingLevel != null &&
                                    _levelBeforeEdit != null &&
                                    _selectedCoolingLevel !=
                                        _levelBeforeEdit) ...[
                                  const SizedBox(height: 8),
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      onPressed: () async {
                                        final levelToSave =
                                            _selectedCoolingLevel;

                                        if (levelToSave == null) return;

                                        try {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text(
                                                'Guardando ajuste...',
                                              ),
                                              duration: Duration(seconds: 1),
                                            ),
                                          );

                                          final body =
                                              await BackendService.updateCoolingLevel(
                                                deviceId: widget.deviceId,
                                                coolingLevel: levelToSave,
                                              );

                                          if (!context.mounted) return;

                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                'Nivel $levelToSave guardado',
                                              ),
                                              duration: const Duration(
                                                seconds: 2,
                                              ),
                                            ),
                                          );
                                          setState(() {
                                            _configCoolingLevel =
                                                _intFromDynamic(
                                                  body['cooling_level'],
                                                ) ??
                                                levelToSave;

                                            _configSetpoint =
                                                _doubleFromDynamic(
                                                  body['setpoint'],
                                                ) ??
                                                _configSetpoint;

                                            _configTurnOnTemp =
                                                _doubleFromDynamic(
                                                  body['turn_on_temperature'],
                                                ) ??
                                                _configTurnOnTemp;

                                            _configTurnOffTemp =
                                                _doubleFromDynamic(
                                                  body['turn_off_temperature'],
                                                ) ??
                                                _configTurnOffTemp;

                                            _selectedCoolingLevel = null;
                                            _levelBeforeEdit = null;
                                            _dialUnlocked = false;
                                          });

                                          await _loadConfigSummary();
                                        } catch (e) {
                                          if (!context.mounted) return;

                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                'Error guardando: $e',
                                              ),
                                              duration: const Duration(
                                                seconds: 4,
                                              ),
                                            ),
                                          );
                                        }
                                      },
                                      icon: const Icon(Icons.save_rounded),
                                      label: const Text('Guardar ajuste'),
                                    ),
                                  ),
                                ],

                                const SizedBox(height: 18),

                                LayoutBuilder(
                                  builder: (context, constraints) {
                                    return GridView.count(
                                      shrinkWrap: true,
                                      physics:
                                          const NeverScrollableScrollPhysics(),
                                      crossAxisCount: 3,
                                      crossAxisSpacing: 8,
                                      mainAxisSpacing: 8,
                                      childAspectRatio:
                                          constraints.maxWidth < 430
                                          ? 0.95
                                          : 1.25,
                                      children: [
                                        _KpiCard(
                                          title: 'Cámara',
                                          value: chamberTemp,
                                          suffix: '°C',
                                          icon: Icons.thermostat_rounded,
                                          badgeText: _sensorAlarmText(
                                            data,
                                            'chamber',
                                          ),
                                          accent: const Color(0xFF1EA7FF),
                                        ),
                                        _KpiCard(
                                          title: 'Evaporador',
                                          value: evaporatorTemp,
                                          suffix: '°C',
                                          icon: Icons.ac_unit_rounded,
                                          badgeText: _sensorAlarmText(
                                            data,
                                            'evaporator',
                                          ),
                                          accent: const Color(0xFF21B9FF),
                                        ),
                                        _MiniCompressorKpi(
                                          relayOn: data['compressor_relay_on'],
                                          shouldBeOn:
                                              data['compressor_should_be_on'],
                                          protectionSeconds:
                                              data['compressor_wait_seconds_remaining'],
                                          connectionStatus: connectionStatus,
                                          secondsSinceLastSeen:
                                              secondsSinceLastSeen,
                                        ),
                                      ],
                                    );
                                  },
                                ),
                                if (defrostEnabled || dripEnabled) ...[
                                  const SizedBox(height: 12),

                                  IntrinsicHeight(
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        if (defrostEnabled)
                                          Expanded(
                                            child: _DefrostCard(
                                              active: data['defrost_active'],
                                              evaporatorTemp: evaporatorTemp,
                                              chamberTemp: chamberTemp,
                                              endTemperature:
                                                  defrostConfig['end_temperature'],
                                              remainingSeconds:
                                                  data['defrost_remaining_seconds'],
                                              nextSeconds:
                                                  data['defrost_next_seconds'],
                                              durationMinutes:
                                                  defrostConfig['duration_minutes'],
                                              intervalMinutes:
                                                  defrostConfig['interval_minutes'],
                                              connectionStatus:
                                                  connectionStatus,
                                              secondsSinceLastSeen:
                                                  secondsSinceLastSeen,
                                            ),
                                          ),

                                        if (defrostEnabled && dripEnabled)
                                          const SizedBox(width: 8),

                                        if (dripEnabled)
                                          Expanded(
                                            child: _DripCard(
                                              active: data['drip_active'],
                                              configuredSeconds:
                                                  dripTimeSeconds,
                                              remainingSeconds:
                                                  data['drip_remaining_seconds'],
                                              connectionStatus:
                                                  connectionStatus,
                                              secondsSinceLastSeen:
                                                  secondsSinceLastSeen,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),

                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Text(
                              lastUpdateText,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Color(0xFF9DB0C1),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  static int? _secondsSinceLastSeen(dynamic value) {
    if (value == null) return null;

    DateTime? lastSeenUtc;

    if (value is Timestamp) {
      lastSeenUtc = value.toDate().toUtc();
    } else if (value is String) {
      final parsed = DateTime.tryParse(value);

      if (parsed != null) {
        lastSeenUtc = DateTime.utc(
          parsed.year,
          parsed.month,
          parsed.day,
          parsed.hour,
          parsed.minute,
          parsed.second,
          parsed.millisecond,
          parsed.microsecond,
        );
      }
    }

    if (lastSeenUtc == null) return null;

    final seconds = DateTime.now().toUtc().difference(lastSeenUtc).inSeconds;

    if (seconds < 0) return 0;

    return seconds;
  }

  static String _connectionStatus(int? seconds) {
    if (seconds == null) return 'offline';
    if (seconds <= 30) return 'online';
    if (seconds <= 90) return 'warning';
    return 'offline';
  }

  static String _lastUpdateText(int? seconds) {
    if (seconds == null) return 'Sin información de actualización';

    if (seconds < 10) return 'Actualizado';

    if (seconds < 60) {
      final roundedSeconds = (seconds ~/ 10) * 10;
      return 'Actualizado hace $roundedSeconds seg';
    }

    final minutes = seconds ~/ 60;

    if (minutes == 1) return 'Actualizado hace 1 min';
    if (minutes < 60) return 'Actualizado hace $minutes min';

    final hours = minutes ~/ 60;

    if (hours == 1) return 'Actualizado hace 1 h';

    return 'Actualizado hace $hours h';
  }

  static int? _intFromDynamic(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is double) return value.round();
    return int.tryParse(value.toString());
  }

  static double? _doubleFromDynamic(dynamic value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  Map<String, double> _coolingConfigForLevel(int level) {
    final safeLevel = level.clamp(1, 7);

    final setpoints = <int, double>{
      1: 7.0,
      2: 6.0,
      3: 5.0,
      4: 4.0,
      5: 3.0,
      6: 2.0,
      7: 1.0,
    };

    final setpoint = setpoints[safeLevel] ?? 4.0;
    const differential = 2.0;

    return {
      'setpoint': setpoint,
      'turn_on_temperature': setpoint + differential,
      'turn_off_temperature': setpoint,
    };
  }

  static dynamic _sensorValue(Map<String, dynamic> data, String role) {
    final readings = data['sensor_readings'];
    if (readings is Map && readings.containsKey(role)) {
      return readings[role];
    }
    return null;
  }

  static String _sensorAlarmText(Map<String, dynamic> data, String role) {
    final alarms = data['sensor_alarms'];
    if (alarms is Map && alarms[role] is Map) {
      final alarm = alarms[role] as Map;
      final inAlarm = alarm['in_alarm'] == true;
      final reason = alarm['reason']?.toString();
      if (inAlarm && reason != null && reason.isNotEmpty) {
        if (reason == 'HIGH_TEMP') return 'ALTA';
        if (reason == 'LOW_TEMP') return 'BAJA';
        return reason.replaceAll('_', ' ');
      }
    }
    return 'NORMAL';
  }
}

class _ServiceToolsBanner extends StatelessWidget {
  const _ServiceToolsBanner({
    required this.deviceId,
    required this.serviceAccessStatus,
    required this.serviceRequested,
    required this.serviceActive,
    required this.serviceExitRequested,
    required this.serviceRequestedAt,
    required this.serviceRequestExpiresSeconds,
    required this.requestInProgress,
    required this.onToggleServiceMode,
  });

  final String deviceId;
  final String serviceAccessStatus;
  final bool serviceRequested;
  final bool serviceActive;
  final bool serviceExitRequested;
  final String? serviceRequestedAt;
  final int serviceRequestExpiresSeconds;
  final bool requestInProgress;
  final ValueChanged<bool> onToggleServiceMode;

  int _remainingSeconds() {
    if (!serviceRequested) return 0;
    if (serviceRequestedAt == null || serviceRequestedAt!.isEmpty) {
      return serviceRequestExpiresSeconds;
    }

    final parsed = DateTime.tryParse(serviceRequestedAt!);

    if (parsed == null) return serviceRequestExpiresSeconds;

    final startedAtUtc = DateTime.utc(
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
      parsed.second,
      parsed.millisecond,
      parsed.microsecond,
    );

    final elapsed = DateTime.now().toUtc().difference(startedAtUtc).inSeconds;
    final remaining = serviceRequestExpiresSeconds - elapsed;

    return remaining < 0 ? 0 : remaining;
  }

  String _formatRemaining(int seconds) {
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return '$minutes:${rest.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final remainingSeconds = _remainingSeconds();
    final requestExpired = serviceRequested && remainingSeconds <= 0;

    final locked =
        requestInProgress ||
        (serviceRequested && !requestExpired && !serviceActive) ||
        serviceExitRequested;

    final targetMode = !serviceActive;

    final String message;
    final String buttonText;

    if (serviceActive) {
      message = 'Modo servicio activo. El AP técnico está disponible.';
      buttonText = 'Salir de servicio';
    } else if (serviceExitRequested) {
      message = 'Salida solicitada. Esperando confirmación del equipo.';
      buttonText = 'Saliendo...';
    } else if (serviceRequested && !requestExpired) {
      message =
          'AP técnico solicitado. Acércate al equipo y conéctate al WiFi SmartCold-Service. Tiempo restante: ${_formatRemaining(remainingSeconds)}';
      buttonText = 'Solicitado';
    } else {
      message = 'El equipo está operando normalmente.';
      buttonText = 'Entrar en servicio';
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.orangeAccent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.75)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.build_circle_rounded,
            color: Colors.orangeAccent,
            size: 32,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Herramientas de servicio',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  requestInProgress ? 'Enviando solicitud...' : message,
                  style: const TextStyle(
                    color: Color(0xFFB8C7D5),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Estado: $serviceAccessStatus',
                  style: const TextStyle(
                    color: Color(0xFF8DA1B2),
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: locked ? null : () => onToggleServiceMode(targetMode),
            child: Text(requestInProgress ? 'Esperando...' : buttonText),
          ),
        ],
      ),
    );
  }
}

class _ServiceModeNotice extends StatelessWidget {
  const _ServiceModeNotice({required this.deviceId});

  final String deviceId;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Card(
          color: const Color(0xFF061A2E),
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.engineering_rounded,
                  color: Colors.orangeAccent,
                  size: 58,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Equipo en mantenimiento técnico',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 21,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  deviceId,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF9DB0C1),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'El equipo está siendo intervenido por un técnico autorizado. '
                  'Durante el mantenimiento la vista normal queda temporalmente deshabilitada.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFFB6C7D6),
                    fontSize: 14,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.connectionStatus, required this.rssi});

  final String connectionStatus;
  final dynamic rssi;

  @override
  Widget build(BuildContext context) {
    final isOnline = connectionStatus == 'online';
    final isWarning = connectionStatus == 'warning';

    final color = isOnline
        ? const Color(0xFF20D76D)
        : isWarning
        ? Colors.orangeAccent
        : Colors.redAccent;

    final label = isOnline
        ? 'ONLINE'
        : isWarning
        ? 'SIN ACTUALIZAR'
        : 'OFFLINE';

    return Row(
      children: [
        IconButton(
          tooltip: 'Volver a equipos',
          icon: const Icon(
            Icons.arrow_back_rounded,
            color: Colors.white,
            size: 30,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        const SizedBox(width: 14),
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF00A8FF), width: 2),
          ),
          child: const Icon(Icons.ac_unit_rounded, color: Color(0xFF00A8FF)),
        ),
        const SizedBox(width: 10),
        const Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: 'SMART',
                  style: TextStyle(color: Colors.white),
                ),
                TextSpan(
                  text: 'COLD',
                  style: TextStyle(color: Color(0xFF00A8FF)),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.2,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, color: color, size: 10),
                const SizedBox(width: 5),
                Text(
                  label == 'SIN ACTUALIZAR' ? 'LENTO' : label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '${rssi ?? "--"} dBm',
              style: const TextStyle(
                color: Color(0xFF9DB0C1),
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _HeroPanel extends StatelessWidget {
  const _HeroPanel({
    required this.deviceName,
    required this.health,
    required this.healthReason,
    required this.state,
    required this.online,
    required this.rssi,
    required this.compressorOn,
    required this.blockReason,
    required this.storeName,
  });

  final dynamic deviceName;
  final dynamic storeName;
  final dynamic health;
  final dynamic healthReason;
  final dynamic state;
  final dynamic online;
  final dynamic rssi;
  final dynamic compressorOn;
  final dynamic blockReason;

  @override
  Widget build(BuildContext context) {
    final nameText = deviceName?.toString() ?? 'Equipo sin nombre';
    final storeText = storeName?.toString() ?? '';
    final rawState = state?.toString();
    final stateText = _estadoEquipo(rawState);
    final stateColor = _stateColor(rawState);
    final stateIcon = _stateIcon(rawState);

    return Container(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: const LinearGradient(
          colors: [Color(0xFF071421), Color(0xFF082846), Color(0xFF071421)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: stateColor.withValues(alpha: 0.55), width: 1),
        boxShadow: [
          BoxShadow(
            color: stateColor.withValues(alpha: 0.16),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            nameText.toUpperCase(),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 19,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.3,
            ),
          ),

          if (storeText.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Local: $storeText',
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF9DB0C1),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(height: 12),

          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: LinearGradient(
                colors: [
                  stateColor.withValues(alpha: 0.18),
                  Colors.white.withValues(alpha: 0.04),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              border: Border.all(color: stateColor.withValues(alpha: 0.32)),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: stateColor.withValues(alpha: 0.18),
                      boxShadow: [
                        BoxShadow(
                          color: stateColor.withValues(alpha: 0.2),
                          blurRadius: 18,
                        ),
                      ],
                    ),
                    child: Icon(stateIcon, color: stateColor, size: 28),
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 56),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'ESTADO DEL EQUIPO',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Color(0xFFB6C7D6),
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        stateText,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: stateColor,
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.4,
                        ),
                      ),
                      const SizedBox(height: 3),
                      if (_stateSubtitle(rawState, blockReason).isNotEmpty)
                        Text(
                          _stateSubtitle(rawState, blockReason),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFD2DEE8),
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _estadoEquipo(dynamic state) {
    final text = state?.toString() ?? '—';

    if (text == 'DRIP') return 'GOTEO';
    if (text == 'DEFROST') return 'DEFROST';
    if (text == 'PROTECTION') return 'PROTECCIÓN';
    if (text == 'COOLING') return 'ENFRIANDO';
    if (text == 'IDLE') return 'ESPERA';

    return text;
  }

  IconData _stateIcon(String? state) {
    if (state == 'DRIP') return Icons.water_drop_rounded;
    if (state == 'DEFROST') return Icons.ac_unit_rounded;
    if (state == 'PROTECTION') return Icons.shield_rounded;
    if (state == 'COOLING') return Icons.severe_cold_rounded;
    if (state == 'IDLE') return Icons.pause_circle_filled_rounded;
    return Icons.info_rounded;
  }

  Color _stateColor(String? state) {
    if (state == 'DRIP') return const Color(0xFF22D3EE);
    if (state == 'DEFROST') return const Color(0xFFA855F7);
    if (state == 'PROTECTION') return const Color(0xFFFFC928);
    if (state == 'COOLING') return const Color(0xFF20D76D);
    if (state == 'IDLE') return const Color(0xFF1EA7FF);
    return const Color(0xFFB6C7D6);
  }

  String _stateSubtitle(String? state, dynamic reason) {
    if (state == 'IDLE') {
      return 'Aún no se alcanza la temperatura de encendido';
    }

    return '';
  }
}

class _CoolingLevelDial extends StatefulWidget {
  const _CoolingLevelDial({
    required this.level,
    required this.setpoint,
    required this.turnOnTemp,
    required this.turnOffTemp,
    required this.unlocked,
    required this.onUnlockChanged,
    required this.onLevelChanged,
  });

  final int level;
  final double setpoint;
  final double turnOnTemp;
  final double turnOffTemp;
  final bool unlocked;
  final ValueChanged<bool> onUnlockChanged;
  final ValueChanged<int> onLevelChanged;

  @override
  State<_CoolingLevelDial> createState() => _CoolingLevelDialState();
}

class _CoolingLevelDialState extends State<_CoolingLevelDial> {
  late final PageController _controller;

  @override
  void initState() {
    super.initState();
    _controller = PageController(
      initialPage: widget.level - 1,
      viewportFraction: 0.16,
    );
  }

  @override
  void didUpdateWidget(covariant _CoolingLevelDial oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.level != widget.level && _controller.hasClients) {
      _controller.animateToPage(
        widget.level - 1,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF00A8FF);

    return SizedBox(
      height: 112,
      width: double.infinity,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            top: 0,
            child: CustomPaint(painter: _EmbeddedDialPainter()),
          ),

          const Positioned(
            top: 0,
            child: Text(
              'NIVEL DE FRÍO',
              style: TextStyle(
                color: Color(0xFF9DB0C1),
                fontSize: 9,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.4,
              ),
            ),
          ),

          Positioned(
            top: 0,
            right: 0,
            child: GestureDetector(
              onTap: () {
                widget.onUnlockChanged(!widget.unlocked);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                decoration: BoxDecoration(
                  color: widget.unlocked
                      ? accent.withValues(alpha: 0.18)
                      : Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: widget.unlocked
                        ? accent.withValues(alpha: 0.45)
                        : Colors.white.withValues(alpha: 0.12),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      widget.unlocked
                          ? Icons.lock_open_rounded
                          : Icons.lock_rounded,
                      color: widget.unlocked ? accent : const Color(0xFF9DB0C1),
                      size: 11,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      widget.unlocked ? 'CANCELAR' : 'DESBLOQ',
                      style: TextStyle(
                        color: widget.unlocked
                            ? accent
                            : const Color(0xFF9DB0C1),
                        fontSize: 8,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          Positioned(
            top: 23,
            left: 0,
            right: 0,
            height: 62,
            child: PageView.builder(
              controller: _controller,
              physics: widget.unlocked
                  ? const PageScrollPhysics()
                  : const NeverScrollableScrollPhysics(),
              itemCount: 7,
              onPageChanged: (index) {
                widget.onLevelChanged(index + 1);
              },
              itemBuilder: (context, index) {
                final number = index + 1;

                return AnimatedBuilder(
                  animation: _controller,
                  builder: (context, child) {
                    double page = widget.level - 1;

                    if (_controller.hasClients &&
                        _controller.position.haveDimensions) {
                      page = _controller.page ?? page;
                    }

                    final distance = (page - index).abs().clamp(0.0, 3.0);
                    final selected = distance < 0.35;
                    final scale = selected ? 1.65 : 1.0 - (distance * 0.12);
                    final opacity = selected ? 1.0 : (0.72 - distance * 0.16);

                    return Transform.translate(
                      offset: const Offset(0, -4),
                      child: Center(
                        child: Transform.scale(
                          scale: scale.clamp(0.68, 1.65),
                          child: Text(
                            '$number',
                            style: TextStyle(
                              color: selected
                                  ? Colors.white
                                  : Colors.white.withValues(
                                      alpha: opacity.clamp(0.22, 0.72),
                                    ),
                              fontSize: selected ? 31 : 21,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),

          Positioned(
            top: 20,
            child: IgnorePointer(
              child: Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: accent, width: 1.35),
                  gradient: RadialGradient(
                    colors: [
                      accent.withValues(alpha: 0.16),
                      const Color(0xFF020B14).withValues(alpha: 0.18),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.28),
                      blurRadius: 18,
                    ),
                  ],
                ),
              ),
            ),
          ),

          Positioned(
            bottom: 18,
            left: 0,
            right: 0,
            child: Row(
              children: [
                Expanded(
                  child: _InlineDialInfo(
                    label: 'ENCIENDE',
                    value: widget.turnOnTemp,
                    color: accent,
                  ),
                ),
                Expanded(
                  child: _InlineDialInfo(
                    label: 'SETPOINT',
                    value: widget.setpoint,
                    color: Colors.white,
                  ),
                ),
                Expanded(
                  child: _InlineDialInfo(
                    label: 'APAGA',
                    value: widget.turnOffTemp,
                    color: accent,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineDialInfo extends StatelessWidget {
  const _InlineDialInfo({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      textAlign: TextAlign.center,
      TextSpan(
        children: [
          TextSpan(
            text: '$label ',
            style: const TextStyle(
              color: Color(0xFF8DA1B2),
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.3,
            ),
          ),
          TextSpan(
            text: '${value.toStringAsFixed(1)}°',
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmbeddedDialPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height * 0.46;

    final softLinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.10)
      ..strokeWidth = 1;

    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.24)
      ..style = PaintingStyle.fill;

    final topRect = Rect.fromLTWH(0, centerY - 37, size.width, 74);
    final rrect = RRect.fromRectAndRadius(topRect, const Radius.circular(60));
    canvas.drawRRect(rrect, shadowPaint);

    // canvas.drawLine(
    //   Offset(0, centerY),
    //   Offset(size.width, centerY),
    //   glowLinePaint,
    // );

    for (int i = 0; i <= 42; i++) {
      final x = size.width * i / 42;
      final major = i % 7 == 0;
      final h = major ? 18.0 : 7.0;

      canvas.drawLine(
        Offset(x, centerY - h / 2),
        Offset(x, centerY + h / 2),
        softLinePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({
    required this.title,
    required this.icon,
    required this.value,
    required this.suffix,
    required this.badgeText,
    required this.accent,
  });

  final String title;
  final IconData icon;
  final dynamic value;
  final String suffix;
  final String badgeText;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final textValue = _formatNumber(value);
    final inAlarm = badgeText != 'NORMAL' && badgeText != 'PROTEGE';
    final cardAccent = inAlarm ? Colors.redAccent : accent;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 115;

        return Container(
          padding: EdgeInsets.all(compact ? 7 : 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              colors: inAlarm
                  ? const [Color(0xFF3A0710), Color(0xFF5A0B18)]
                  : const [Color(0xFF062033), Color(0xFF082B49)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            border: Border.all(color: cardAccent.withValues(alpha: 0.85)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: cardAccent, size: compact ? 15 : 17),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      title.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: compact ? 10 : 12,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.center,
                    child: Text.rich(
                      textAlign: TextAlign.center,
                      TextSpan(
                        children: [
                          TextSpan(
                            text: textValue,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 38,
                              fontWeight: FontWeight.w900,
                              height: 0.9,
                            ),
                          ),
                          TextSpan(
                            text: ' $suffix',
                            style: TextStyle(
                              color: cardAccent,
                              fontSize: compact ? 12 : 14,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 5),
              Center(
                child: _TinyPill(
                  icon: Icons.thermostat_rounded,
                  text: inAlarm ? badgeText : 'NORMAL',
                  color: inAlarm ? Colors.redAccent : const Color(0xFF20D76D),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DefrostCard extends StatelessWidget {
  const _DefrostCard({
    required this.active,
    required this.evaporatorTemp,
    required this.chamberTemp,
    required this.endTemperature,
    required this.remainingSeconds,
    required this.nextSeconds,
    required this.durationMinutes,
    required this.intervalMinutes,
    required this.connectionStatus,
    required this.secondsSinceLastSeen,
  });

  final dynamic active;
  final dynamic evaporatorTemp;
  final dynamic chamberTemp;
  final dynamic endTemperature;
  final dynamic remainingSeconds;
  final dynamic nextSeconds;
  final dynamic durationMinutes;
  final dynamic intervalMinutes;
  final String connectionStatus;
  final int? secondsSinceLastSeen;

  @override
  Widget build(BuildContext context) {
    final isActive = active == true;

    final baseSeconds = isActive
        ? _toInt(remainingSeconds)
        : _toInt(nextSeconds);

    final elapsed = connectionStatus == 'online'
        ? (secondsSinceLastSeen ?? 0)
        : 0;

    final displaySeconds = baseSeconds == null
        ? null
        : (baseSeconds - elapsed).clamp(0, 999999);

    return _GlassCard(
      borderColor: const Color(0xFFA855F7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(
            icon: Icons.ac_unit_rounded,
            title: 'DEFROST',
            badge: isActive ? 'ACTIVO' : 'INACTIVO',
            color: const Color(0xFFA855F7),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _MiniMetric(
                  label: 'Temp. fin',
                  value: endTemperature,
                  suffix: '°C',
                  color: const Color(0xFFC084FC),
                  icon: Icons.thermostat_rounded,
                ),
              ),
              _VerticalDivider(),
              Expanded(
                child: _MiniMetric(
                  label: isActive ? 'Restante' : 'Próximo',
                  value: displaySeconds,
                  suffix: 's',
                  color: const Color(0xFFC084FC),
                  icon: Icons.timer_rounded,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is double) return value.round();
    return int.tryParse(value.toString());
  }
}

class _DripCard extends StatelessWidget {
  const _DripCard({
    required this.active,
    required this.configuredSeconds,
    required this.remainingSeconds,
    required this.connectionStatus,
    required this.secondsSinceLastSeen,
  });

  final dynamic active;
  final dynamic configuredSeconds;
  final dynamic remainingSeconds;
  final String connectionStatus;
  final int? secondsSinceLastSeen;

  @override
  Widget build(BuildContext context) {
    final isActive = active == true;

    final baseSeconds = isActive
        ? _toInt(remainingSeconds)
        : _toInt(configuredSeconds);

    final elapsed = connectionStatus == 'online'
        ? (secondsSinceLastSeen ?? 0)
        : 0;

    final displaySeconds = isActive
        ? (baseSeconds == null
              ? null
              : (baseSeconds - elapsed).clamp(0, 999999))
        : baseSeconds;

    return _GlassCard(
      borderColor: const Color(0xFF00D5D5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(
            icon: Icons.water_drop_rounded,
            title: 'GOTEO',
            badge: isActive ? 'ACTIVO' : 'INACTIVO',
            color: const Color(0xFF00D5D5),
          ),
          const SizedBox(height: 8),
          Center(
            child: _MiniMetric(
              label: isActive ? 'Restante' : 'Configurado',
              value: displaySeconds,
              suffix: 's',
              color: const Color(0xFF22D3EE),
              icon: Icons.timer_rounded,
            ),
          ),
        ],
      ),
    );
  }

  static int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is double) return value.round();
    return int.tryParse(value.toString());
  }
}

class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child, required this.borderColor});

  final Widget child;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          colors: [
            const Color(0xFF061A2E).withValues(alpha: 0.96),
            const Color(0xFF08263F).withValues(alpha: 0.96),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: borderColor.withValues(alpha: 0.65)),
        boxShadow: [
          BoxShadow(
            color: borderColor.withValues(alpha: 0.12),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.badge,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String badge;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: color, size: 13),
        const SizedBox(width: 3),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        const SizedBox(width: 3),
        Flexible(
          child: Align(
            alignment: Alignment.centerRight,
            child: _GlowBadge(text: badge, color: color),
          ),
        ),
      ],
    );
  }
}

class _GlowBadge extends StatelessWidget {
  const _GlowBadge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 8,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _MiniMetric extends StatelessWidget {
  const _MiniMetric({
    required this.label,
    required this.value,
    required this.suffix,
    required this.color,
    this.icon,
  });

  final String label;
  final dynamic value;
  final String suffix;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final formatted = _formatNumber(value);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFFD2DEE8),
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, color: color, size: 25),
                const SizedBox(width: 6),
              ],
              Text(
                formatted,
                style: TextStyle(
                  color: color,
                  fontSize: 28,
                  height: 0.95,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                suffix,
                style: TextStyle(
                  color: color,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _VerticalDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 62,
      margin: const EdgeInsets.symmetric(horizontal: 14),
      color: Colors.white.withValues(alpha: 0.16),
    );
  }
}

String _formatNumber(dynamic value) {
  if (value == null) return '—';

  if (value is int) {
    return value.toString();
  }

  if (value is double) {
    return value.toStringAsFixed(2);
  }

  if (value is num) {
    return value.toStringAsFixed(2);
  }

  return value.toString();
}

class _MiniCompressorKpi extends StatelessWidget {
  const _MiniCompressorKpi({
    required this.relayOn,
    required this.shouldBeOn,
    required this.protectionSeconds,
    required this.connectionStatus,
    required this.secondsSinceLastSeen,
  });

  final dynamic relayOn;
  final dynamic shouldBeOn;
  final dynamic protectionSeconds;
  final String connectionStatus;
  final int? secondsSinceLastSeen;

  @override
  Widget build(BuildContext context) {
    final isOn = relayOn == true;
    const accent = Color(0xFF20D76D);

    final baseSeconds = _toInt(protectionSeconds) ?? 0;

    final elapsed = connectionStatus == 'online'
        ? (secondsSinceLastSeen ?? 0)
        : 0;

    final displaySeconds = (baseSeconds - elapsed).clamp(0, 999999);

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          colors: [Color(0xFF042619), Color(0xFF063D2B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: accent.withValues(alpha: 0.65)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.settings_input_component_rounded,
                color: accent,
                size: 15,
              ),
              SizedBox(width: 4),
              Expanded(
                child: Text(
                  'COMPRESOR',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 9.8,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          Expanded(
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  isOn ? 'ON' : 'OFF',
                  style: const TextStyle(
                    color: accent,
                    fontSize: 34,
                    fontWeight: FontWeight.w900,
                    height: 0.9,
                  ),
                ),
              ),
            ),
          ),
          Center(
            child: _TinyPill(
              icon: Icons.timer_rounded,
              text: 'PROT. ${displaySeconds}s',
              color: accent,
            ),
          ),
        ],
      ),
    );
  }

  static int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is double) return value.round();
    return int.tryParse(value.toString());
  }
}

class _TinyPill extends StatelessWidget {
  const _TinyPill({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 11),
          const SizedBox(width: 3),
          Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 8.5,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class ClientsPage extends StatelessWidget {
  const ClientsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final clientsQuery = FirebaseFirestore.instance
        .collection('clients')
        .where('active', isEqualTo: true);

    return Scaffold(
      backgroundColor: const Color(0xFF020B14),
      appBar: AppBar(
        title: const Text('Clientes'),
        backgroundColor: const Color(0xFF061A2E),
        actions: [
          IconButton(
            tooltip: 'Nuevo cliente',
            icon: const Icon(Icons.add_business_rounded),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CreateClientPage()),
              );
            },
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: clientsQuery.snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Error cargando clientes:\n${snapshot.error}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            );
          }

          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final clients = snapshot.data!.docs;

          if (clients.isEmpty) {
            return const Center(
              child: Text(
                'No hay clientes registrados',
                style: TextStyle(color: Colors.white),
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: clients.length,
            itemBuilder: (context, index) {
              final doc = clients[index];
              final data = doc.data();
              return _ClientSummaryCard(clientId: doc.id, clientData: data);
            },
          );
        },
      ),
    );
  }
}

class CreateClientPage extends StatefulWidget {
  const CreateClientPage({super.key});

  @override
  State<CreateClientPage> createState() => _CreateClientPageState();
}

class _CreateClientPageState extends State<CreateClientPage> {
  final _nameController = TextEditingController();
  final _cedulaController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();

  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _cedulaController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _createClient() async {
    final name = _nameController.text.trim();
    final cedulaRuc = _cedulaController.text.trim();
    final email = _emailController.text.trim().toLowerCase();
    final phone = _phoneController.text.trim();

    if (name.isEmpty || cedulaRuc.isEmpty || email.isEmpty) {
      setState(() {
        _error = 'Nombre, cédula/RUC y correo son obligatorios.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final response = await http.post(
        Uri.parse(
          'https://smartcold-api-649501100610.us-central1.run.app/api/clients',
        ),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': name,
          'cedula_ruc': cedulaRuc,
          'email': email,
          'phone': phone,
        }),
      );

      final body = jsonDecode(response.body);

      if (response.statusCode != 200 || body['success'] != true) {
        throw Exception(body['message'] ?? 'No se pudo crear el cliente');
      }

      if (!mounted) return;

      await showDialog<void>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Cliente creado'),
            content: Text(
              'Cliente y usuario creados correctamente.\n\n'
              'Correo: $email\n'
              'Clave temporal: $cedulaRuc',
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Aceptar'),
              ),
            ],
          );
        },
      );

      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = 'Error creando cliente: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF020B14),
      appBar: AppBar(
        title: const Text('Nuevo cliente'),
        backgroundColor: const Color(0xFF061A2E),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Crear cliente y usuario',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'El usuario podrá ingresar con su correo y cédula/RUC como clave temporal.',
            style: TextStyle(color: Color(0xFF9DB0C1)),
          ),
          const SizedBox(height: 18),

          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Nombre del cliente',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),

          TextField(
            controller: _cedulaController,
            decoration: const InputDecoration(
              labelText: 'Cédula/RUC',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),

          TextField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'Correo de acceso',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),

          TextField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Teléfono',
              border: OutlineInputBorder(),
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],

          const SizedBox(height: 18),

          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _loading ? null : _createClient,
              icon: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.person_add_alt_1_rounded),
              label: Text(_loading ? 'Creando...' : 'Crear cliente'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ClientSummaryCard extends StatelessWidget {
  const _ClientSummaryCard({required this.clientId, required this.clientData});

  final String clientId;
  final Map<String, dynamic> clientData;

  @override
  Widget build(BuildContext context) {
    final name = clientData['name']?.toString() ?? 'Cliente sin nombre';

    final devicesQuery = FirebaseFirestore.instance
        .collection('devices')
        .where('active', isEqualTo: true)
        .where('current_client_id', isEqualTo: clientId);

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: devicesQuery.snapshots(),
      builder: (context, snapshot) {
        final devicesCount = snapshot.data?.docs.length ?? 0;

        return Card(
          color: const Color(0xFF061A2E),
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ClientDetailPage(
                    clientId: clientId,
                    clientData: clientData,
                  ),
                ),
              );
            },
            leading: const Icon(
              Icons.business_rounded,
              color: Color(0xFF00A8FF),
            ),
            title: Text(
              name,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
              ),
            ),
            subtitle: Text(
              '$devicesCount equipo${devicesCount == 1 ? '' : 's'} asociado${devicesCount == 1 ? '' : 's'}',
              style: const TextStyle(color: Color(0xFF9DB0C1)),
            ),
            trailing: const Icon(
              Icons.chevron_right_rounded,
              color: Colors.white,
            ),
          ),
        );
      },
    );
  }
}

class ClientDetailPage extends StatefulWidget {
  const ClientDetailPage({
    super.key,
    required this.clientId,
    required this.clientData,
  });

  final String clientId;
  final Map<String, dynamic> clientData;

  @override
  State<ClientDetailPage> createState() => _ClientDetailPageState();
}

class _ClientDetailPageState extends State<ClientDetailPage> {
  late String _currentClientId;
  late Map<String, dynamic> _currentClientData;

  @override
  void initState() {
    super.initState();
    _currentClientId = widget.clientId;
    _currentClientData = widget.clientData;
  }

  @override
  Widget build(BuildContext context) {
    final name = _currentClientData['name']?.toString() ?? 'Cliente sin nombre';
    final email = _currentClientData['email']?.toString() ?? '—';
    final phone = _currentClientData['phone']?.toString() ?? '—';

    final storesQuery = FirebaseFirestore.instance
        .collection('stores')
        .where('active', isEqualTo: true)
        .where('client_id', isEqualTo: _currentClientId);
    final usersQuery = FirebaseFirestore.instance
        .collection('users')
        .where('active', isEqualTo: true)
        .where('client_id', isEqualTo: _currentClientId);
    return Scaffold(
      backgroundColor: const Color(0xFF020B14),
      appBar: AppBar(
        title: Text(name),
        backgroundColor: const Color(0xFF061A2E),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _ClientSelectorTile(
            selectedClientId: _currentClientId,
            selectedClientName: name,
            onClientSelected: (newClientId, newClientData) {
              setState(() {
                _currentClientId = newClientId;
                _currentClientData = newClientData;
              });
            },
          ),
          _AccountInfoTile(
            icon: Icons.email_rounded,
            title: 'Correo',
            value: email,
          ),
          _AccountInfoTile(
            icon: Icons.phone_rounded,
            title: 'Teléfono',
            value: phone,
          ),
          const SizedBox(height: 18),
          const Text(
            'Locales asociados',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),

          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CreateStorePage(clientId: _currentClientId),
                  ),
                );
              },
              icon: const Icon(Icons.add_business_rounded),
              label: const Text('Agregar local'),
            ),
          ),
          const SizedBox(height: 10),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: storesQuery.snapshots(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const Text(
                  'Error cargando locales',
                  style: TextStyle(color: Colors.redAccent),
                );
              }

              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final stores = snapshot.data!.docs;

              if (stores.isEmpty) {
                return const Text(
                  'Este cliente no tiene locales asociados todavía.',
                  style: TextStyle(color: Color(0xFF9DB0C1)),
                );
              }

              return Column(
                children: stores.map((doc) {
                  final data = doc.data();
                  final storeName =
                      data['name']?.toString() ?? 'Local sin nombre';
                  final address = data['address']?.toString() ?? '';

                  return Card(
                    color: const Color(0xFF061A2E),
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ListTile(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => StoreDetailPage(
                              storeId: doc.id,
                              storeData: data,
                            ),
                          ),
                        );
                      },
                      leading: const Icon(
                        Icons.storefront_rounded,
                        color: Color(0xFF00A8FF),
                      ),
                      title: Text(
                        storeName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      subtitle: Text(
                        address.isEmpty ? 'Sin dirección registrada' : address,
                        style: const TextStyle(color: Color(0xFF9DB0C1)),
                      ),
                      trailing: const Icon(
                        Icons.chevron_right_rounded,
                        color: Colors.white,
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
          const SizedBox(height: 18),
          const Text(
            'Usuarios asociados',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Agregar usuario pendiente')),
                );
              },
              icon: const Icon(Icons.person_add_rounded),
              label: const Text('Agregar usuario'),
            ),
          ),
          const SizedBox(height: 10),
          const SizedBox(height: 10),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: usersQuery.snapshots(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const Text(
                  'Error cargando usuarios',
                  style: TextStyle(color: Colors.redAccent),
                );
              }

              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final users = snapshot.data!.docs;

              if (users.isEmpty) {
                return const Text(
                  'Este cliente no tiene usuarios asociados todavía.',
                  style: TextStyle(color: Color(0xFF9DB0C1)),
                );
              }

              return Column(
                children: users.map((doc) {
                  final data = doc.data();
                  final email =
                      data['email']?.toString() ?? 'Usuario sin correo';
                  final role = data['role']?.toString() ?? 'sin rol';
                  final active = data['active'] == true;

                  return Card(
                    color: const Color(0xFF061A2E),
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ListTile(
                      leading: const Icon(
                        Icons.person_rounded,
                        color: Color(0xFF00A8FF),
                      ),
                      title: Text(
                        email,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      subtitle: Text(
                        'Rol: $role · ${active ? 'Activo' : 'Inactivo'}',
                        style: const TextStyle(color: Color(0xFF9DB0C1)),
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ClientSelectorTile extends StatefulWidget {
  const _ClientSelectorTile({
    required this.selectedClientId,
    required this.selectedClientName,
    required this.onClientSelected,
  });

  final String selectedClientId;
  final String selectedClientName;
  final void Function(String clientId, Map<String, dynamic> clientData)
  onClientSelected;

  @override
  State<_ClientSelectorTile> createState() => _ClientSelectorTileState();
}

class _ClientSelectorTileState extends State<_ClientSelectorTile> {
  String _searchText = '';

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF061A2E),
      child: ListTile(
        leading: const Icon(Icons.business_rounded, color: Color(0xFF00A8FF)),
        title: const Text(
          'Cliente',
          style: TextStyle(color: Color(0xFF9DB0C1)),
        ),
        subtitle: Text(
          widget.selectedClientName,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
          ),
        ),
        trailing: const Icon(
          Icons.keyboard_arrow_down_rounded,
          color: Colors.white,
        ),
        onTap: () async {
          final selected =
              await showModalBottomSheet<
                QueryDocumentSnapshot<Map<String, dynamic>>
              >(
                context: context,
                isScrollControlled: true,
                backgroundColor: const Color(0xFF020B14),
                builder: (context) {
                  final clientsQuery = FirebaseFirestore.instance
                      .collection('clients')
                      .where('active', isEqualTo: true);

                  return StatefulBuilder(
                    builder: (context, setModalState) {
                      return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                        stream: clientsQuery.snapshots(),
                        builder: (context, snapshot) {
                          if (!snapshot.hasData) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }

                          final clients = snapshot.data!.docs;

                          final filteredClients = clients.where((doc) {
                            final data = doc.data();
                            final name =
                                data['name']?.toString().toLowerCase() ?? '';
                            return name.contains(_searchText.toLowerCase());
                          }).toList();

                          return SafeArea(
                            child: Padding(
                              padding: EdgeInsets.only(
                                left: 16,
                                right: 16,
                                top: 16,
                                bottom:
                                    MediaQuery.of(context).viewInsets.bottom +
                                    16,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text(
                                    'Seleccionar cliente',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  const SizedBox(height: 14),
                                  TextField(
                                    onChanged: (value) {
                                      setModalState(() {
                                        _searchText = value.trim();
                                      });
                                    },
                                    decoration: const InputDecoration(
                                      hintText: 'Buscar cliente...',
                                      prefixIcon: Icon(Icons.search_rounded),
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Flexible(
                                    child: ListView(
                                      shrinkWrap: true,
                                      children: filteredClients.map((doc) {
                                        final data = doc.data();
                                        final name =
                                            data['name']?.toString() ??
                                            'Cliente sin nombre';

                                        return ListTile(
                                          leading: Icon(
                                            doc.id == widget.selectedClientId
                                                ? Icons.check_circle_rounded
                                                : Icons.business_rounded,
                                            color: const Color(0xFF00A8FF),
                                          ),
                                          title: Text(
                                            name,
                                            style: const TextStyle(
                                              color: Colors.white,
                                            ),
                                          ),
                                          onTap: () {
                                            Navigator.pop(context, doc);
                                          },
                                        );
                                      }).toList(),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                  );
                },
              );

          if (selected == null) return;

          setState(() {
            _searchText = '';
          });

          widget.onClientSelected(selected.id, selected.data());
        },
      ),
    );
  }
}

class _ClientDocumentSearchSheet extends StatefulWidget {
  const _ClientDocumentSearchSheet({required this.selectedClientId});

  final String selectedClientId;

  @override
  State<_ClientDocumentSearchSheet> createState() =>
      _ClientDocumentSearchSheetState();
}

class _ClientDocumentSearchSheetState
    extends State<_ClientDocumentSearchSheet> {
  String _searchText = '';

  @override
  Widget build(BuildContext context) {
    final clientsQuery = FirebaseFirestore.instance
        .collection('clients')
        .where('active', isEqualTo: true);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: clientsQuery.snapshots(),
          builder: (context, snapshot) {
            final clients = snapshot.data?.docs ?? [];

            final filteredClients = clients.where((doc) {
              final data = doc.data();
              final name = data['name']?.toString().toLowerCase() ?? '';
              return name.contains(_searchText.toLowerCase());
            }).toList();

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Seleccionar cliente',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  onChanged: (value) {
                    setState(() {
                      _searchText = value.trim();
                    });
                  },
                  decoration: const InputDecoration(
                    hintText: 'Buscar cliente...',
                    prefixIcon: Icon(Icons.search_rounded),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: filteredClients.map((doc) {
                      final data = doc.data();
                      final name =
                          data['name']?.toString() ?? 'Cliente sin nombre';

                      return ListTile(
                        leading: Icon(
                          doc.id == widget.selectedClientId
                              ? Icons.check_circle_rounded
                              : Icons.business_rounded,
                          color: const Color(0xFF00A8FF),
                        ),
                        title: Text(
                          name,
                          style: const TextStyle(color: Colors.white),
                        ),
                        onTap: () {
                          Navigator.pop(context, doc);
                        },
                      );
                    }).toList(),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class CreateStorePage extends StatefulWidget {
  const CreateStorePage({super.key, required this.clientId});

  final String clientId;

  @override
  State<CreateStorePage> createState() => _CreateStorePageState();
}

class _CreateStorePageState extends State<CreateStorePage> {
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();
  final _phoneController = TextEditingController();

  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _createStore() async {
    final name = _nameController.text.trim();
    final address = _addressController.text.trim();
    final phone = _phoneController.text.trim();

    if (name.isEmpty) {
      setState(() {
        _error = 'El nombre del local es obligatorio.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final response = await http.post(
        Uri.parse(
          'https://smartcold-api-649501100610.us-central1.run.app/api/stores',
        ),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'client_id': widget.clientId,
          'name': name,
          'address': address,
          'phone': phone,
        }),
      );

      final body = jsonDecode(response.body);

      if (response.statusCode != 200 || body['success'] != true) {
        throw Exception(body['message'] ?? 'No se pudo crear el local');
      }

      if (!mounted) return;

      await showDialog<void>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Local creado'),
            content: Text('El local "$name" fue creado correctamente.'),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Aceptar'),
              ),
            ],
          );
        },
      );

      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = 'Error creando local: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF020B14),
      appBar: AppBar(
        title: const Text('Nuevo local'),
        backgroundColor: const Color(0xFF061A2E),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Crear local',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Este local quedará asociado al cliente seleccionado.',
            style: TextStyle(color: Color(0xFF9DB0C1)),
          ),
          const SizedBox(height: 18),

          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Nombre del local',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),

          TextField(
            controller: _addressController,
            decoration: const InputDecoration(
              labelText: 'Dirección',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),

          TextField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Teléfono',
              border: OutlineInputBorder(),
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],

          const SizedBox(height: 18),

          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _loading ? null : _createStore,
              icon: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.storefront_rounded),
              label: Text(_loading ? 'Creando...' : 'Crear local'),
            ),
          ),
        ],
      ),
    );
  }
}

class StoreDetailPage extends StatefulWidget {
  const StoreDetailPage({
    super.key,
    required this.storeId,
    required this.storeData,
  });

  final String storeId;
  final Map<String, dynamic> storeData;

  @override
  State<StoreDetailPage> createState() => _StoreDetailPageState();
}

class _StoreDetailPageState extends State<StoreDetailPage> {
  late String _currentStoreId;
  late Map<String, dynamic> _currentStoreData;

  @override
  void initState() {
    super.initState();
    _currentStoreId = widget.storeId;
    _currentStoreData = widget.storeData;
  }

  @override
  Widget build(BuildContext context) {
    final storeName =
        _currentStoreData['name']?.toString() ?? 'Local sin nombre';

    final address = _currentStoreData['address']?.toString() ?? '—';

    final devicesQuery = FirebaseFirestore.instance
        .collection('devices')
        .where('active', isEqualTo: true)
        .where('current_store_id', isEqualTo: _currentStoreId);

    return Scaffold(
      backgroundColor: const Color(0xFF020B14),
      appBar: AppBar(
        title: Text(storeName),
        backgroundColor: const Color(0xFF061A2E),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StoreSelectorTile(
            selectedStoreId: _currentStoreId,
            selectedStoreName: storeName,
            clientId: _currentStoreData['client_id']?.toString() ?? '',
            onStoreSelected: (newStoreId, newStoreData) {
              setState(() {
                _currentStoreId = newStoreId;
                _currentStoreData = newStoreData;
              });
            },
          ),
          _AccountInfoTile(
            icon: Icons.location_on_rounded,
            title: 'Dirección',
            value: address,
          ),
          const SizedBox(height: 18),
          const Text(
            'Equipos del local',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 10),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: devicesQuery.snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final devices = snapshot.data!.docs;

              if (devices.isEmpty) {
                return const Text(
                  'Este local no tiene equipos asociados todavía.',
                  style: TextStyle(color: Color(0xFF9DB0C1)),
                );
              }

              return Column(
                children: devices.map((doc) {
                  return _DeviceSummaryCard(
                    deviceId: doc.id,
                    deviceData: doc.data(),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => DeviceStatusPage(deviceId: doc.id),
                        ),
                      );
                    },
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _StoreSelectorTile extends StatefulWidget {
  const _StoreSelectorTile({
    required this.selectedStoreId,
    required this.selectedStoreName,
    required this.clientId,
    required this.onStoreSelected,
  });

  final String selectedStoreId;
  final String selectedStoreName;
  final String clientId;
  final void Function(String storeId, Map<String, dynamic> storeData)
  onStoreSelected;

  @override
  State<_StoreSelectorTile> createState() => _StoreSelectorTileState();
}

class _StoreSelectorTileState extends State<_StoreSelectorTile> {
  String _searchText = '';

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF061A2E),
      child: ListTile(
        leading: const Icon(Icons.storefront_rounded, color: Color(0xFF00A8FF)),
        title: const Text('Local', style: TextStyle(color: Color(0xFF9DB0C1))),
        subtitle: Text(
          widget.selectedStoreName,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
          ),
        ),
        trailing: const Icon(
          Icons.keyboard_arrow_down_rounded,
          color: Colors.white,
        ),
        onTap: () async {
          final selected =
              await showModalBottomSheet<
                QueryDocumentSnapshot<Map<String, dynamic>>
              >(
                context: context,
                isScrollControlled: true,
                backgroundColor: const Color(0xFF020B14),
                builder: (context) {
                  final storesQuery = FirebaseFirestore.instance
                      .collection('stores')
                      .where('active', isEqualTo: true)
                      .where('client_id', isEqualTo: widget.clientId);

                  return StatefulBuilder(
                    builder: (context, setModalState) {
                      return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                        stream: storesQuery.snapshots(),
                        builder: (context, snapshot) {
                          if (!snapshot.hasData) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }

                          final stores = snapshot.data!.docs;

                          final filteredStores = stores.where((doc) {
                            final data = doc.data();
                            final name =
                                data['name']?.toString().toLowerCase() ?? '';
                            return name.contains(_searchText.toLowerCase());
                          }).toList();

                          return SafeArea(
                            child: Padding(
                              padding: EdgeInsets.only(
                                left: 16,
                                right: 16,
                                top: 16,
                                bottom:
                                    MediaQuery.of(context).viewInsets.bottom +
                                    16,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text(
                                    'Seleccionar local',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  const SizedBox(height: 14),
                                  TextField(
                                    onChanged: (value) {
                                      setModalState(() {
                                        _searchText = value.trim();
                                      });
                                    },
                                    decoration: const InputDecoration(
                                      hintText: 'Buscar local...',
                                      prefixIcon: Icon(Icons.search_rounded),
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Flexible(
                                    child: ListView(
                                      shrinkWrap: true,
                                      children: filteredStores.map((doc) {
                                        final data = doc.data();
                                        final name =
                                            data['name']?.toString() ??
                                            'Local sin nombre';

                                        return ListTile(
                                          leading: Icon(
                                            doc.id == widget.selectedStoreId
                                                ? Icons.check_circle_rounded
                                                : Icons.storefront_rounded,
                                            color: const Color(0xFF00A8FF),
                                          ),
                                          title: Text(
                                            name,
                                            style: const TextStyle(
                                              color: Colors.white,
                                            ),
                                          ),
                                          onTap: () {
                                            Navigator.pop(context, doc);
                                          },
                                        );
                                      }).toList(),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                  );
                },
              );

          if (selected == null) return;

          setState(() {
            _searchText = '';
          });

          widget.onStoreSelected(selected.id, selected.data());
        },
      ),
    );
  }
}

class NewInstallationPage extends StatefulWidget {
  const NewInstallationPage({super.key});

  @override
  State<NewInstallationPage> createState() => _NewInstallationPageState();
}

class _NewInstallationPageState extends State<NewInstallationPage> {
  static const String _espBaseUrl = 'http://192.168.4.1';

  bool _loading = false;
  String? _error;
  Map<String, dynamic>? _deviceInfo;
  Map<String, dynamic>? _initialConfiguration;
  List<ProgressStepData> _progressSteps = [];

  void _showProgressDialog(String title, List<String> steps) {
    _progressSteps = steps
        .map((step) => ProgressStepData(title: step))
        .toList();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            _progressDialogSetState = setDialogState;

            return OperationProgressDialog(title: title, steps: _progressSteps);
          },
        );
      },
    );
  }

  StateSetter? _progressDialogSetState;

  void _setProgressStep(int index, ProgressStepState state) {
    if (index < 0 || index >= _progressSteps.length) return;

    _progressSteps[index].state = state;

    _progressDialogSetState?.call(() {});
  }

  void _closeProgressDialog() {
    _progressDialogSetState = null;

    if (Navigator.canPop(context)) {
      Navigator.pop(context);
    }
  }

  String? get _deviceId => _deviceInfo?['device_id']?.toString();

  Future<void> _loadDeviceInfo() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final response = await http
          .get(Uri.parse('$_espBaseUrl/api/device-info'))
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final data = jsonDecode(response.body);

      if (!mounted) return;

      setState(() {
        _deviceInfo = Map<String, dynamic>.from(data);

        if (data['parameters_configured'] == true) {
          _initialConfiguration = {
            'operation_mode': data['operation_mode'],
            'cooling_level': data['cooling_level'],
            'setpoint': data['setpoint'],
            'differential': data['differential'],
            'min_off_seconds': data['min_off_seconds'],
          };
        }
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        debugPrint('ERROR LEYENDO ESP /api/device-info: $e');

        _error =
            'No se pudo leer el ESP.\n\n'
            'Detalle: $e\n\n'
            'Verifica que el teléfono esté conectado al AP SmartCold.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _scanWifi() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final response = await http
          .get(Uri.parse('$_espBaseUrl/api/wifi/scan'))
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final data = jsonDecode(response.body);
      final networksRaw = data['networks'];

      final networks = networksRaw is List
          ? networksRaw
                .whereType<Map>()
                .map((item) => Map<String, dynamic>.from(item))
                .toList()
          : <Map<String, dynamic>>[];

      if (!mounted) return;

      final result = await showModalBottomSheet<Map<String, String>>(
        context: context,
        isScrollControlled: true,
        backgroundColor: const Color(0xFF020B14),
        builder: (context) {
          return _WifiConfigSheet(networks: networks);
        },
      );

      if (result == null) return;

      await _sendWifiConfig(result['ssid']!, result['password']!);
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = 'Error escaneando WiFi: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _sendWifiConfig(String ssid, String password) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    _showProgressDialog('Configurando SmartCold', [
      'Enviando credenciales al equipo',
      'Esperando conexión WiFi',
      'Leyendo estado actualizado',
    ]);

    try {
      _setProgressStep(0, ProgressStepState.running);

      final response = await http
          .post(
            Uri.parse('$_espBaseUrl/api/wifi/configure'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'ssid': ssid, 'password': password}),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        _setProgressStep(0, ProgressStepState.error);
        throw Exception('HTTP ${response.statusCode}');
      }

      _setProgressStep(0, ProgressStepState.success);
      _setProgressStep(1, ProgressStepState.running);

      await Future.delayed(const Duration(seconds: 8));

      _setProgressStep(1, ProgressStepState.success);
      _setProgressStep(2, ProgressStepState.success);

      await Future.delayed(const Duration(milliseconds: 700));

      if (mounted) {
        _closeProgressDialog();

        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (context) {
            return AlertDialog(
              title: const Text('WiFi configurado'),
              content: Text(
                'El equipo se conectó correctamente a la red "$ssid".\n\n'
                'Si la app no actualiza de inmediato, mantén el teléfono conectado al AP SmartCold y presiona Actualizar.',
              ),
              actions: [
                ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Continuar'),
                ),
              ],
            );
          },
        );

        await _loadDeviceInfo();
      }
    } catch (e) {
      _setProgressStep(1, ProgressStepState.error);

      await Future.delayed(const Duration(milliseconds: 800));

      if (mounted) {
        _closeProgressDialog();

        setState(() {
          _error =
              'No se pudo conectar el equipo al WiFi. Verifica la contraseña e inténtalo nuevamente.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _detectAndAssignSensors() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final response = await http
          .get(Uri.parse('$_espBaseUrl/api/install/sensors'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }

      final data = jsonDecode(response.body);
      final sensorsRaw = data['sensors'];

      final sensors = sensorsRaw is List
          ? sensorsRaw
                .whereType<Map>()
                .map((item) => Map<String, dynamic>.from(item))
                .toList()
          : <Map<String, dynamic>>[];

      if (sensors.isEmpty) {
        throw Exception('No se detectaron sensores DS18B20.');
      }

      if (!mounted) return;

      final initialSensors = <String, Map<String, dynamic>>{};

      for (final sensor in sensors) {
        final address = sensor['address']?.toString() ?? '';
        if (address.isEmpty) continue;

        if (sensor['configured'] == true) {
          initialSensors[address] = Map<String, dynamic>.from(sensor);
        }
      }

      final assigned =
          await showModalBottomSheet<Map<String, Map<String, dynamic>>>(
            context: context,
            isScrollControlled: true,
            backgroundColor: const Color(0xFF020B14),
            builder: (context) {
              return _AssignSensorRolesSheet(
                sensors: sensors,
                initialSensors: initialSensors,
                initialOperationMode:
                    _deviceInfo?['operation_mode']?.toString() == 'freeze'
                    ? 'freeze'
                    : 'refrigerate',
                initialCoolingLevel:
                    int.tryParse(
                      _deviceInfo?['cooling_level']?.toString() ?? '',
                    ) ??
                    4,
              );
            },
          );

      if (assigned == null) return;

      final saveResponse = await http
          .post(
            Uri.parse('$_espBaseUrl/api/install/sensors'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'sensors': assigned.values.toList()}),
          )
          .timeout(const Duration(seconds: 10));

      if (saveResponse.statusCode != 200) {
        throw Exception(
          'HTTP ${saveResponse.statusCode}: ${saveResponse.body}',
        );
      }

      final chamberConfig = assigned.values.firstWhere(
        (sensor) => sensor['role']?.toString() == 'chamber',
        orElse: () => <String, dynamic>{},
      );

      if (chamberConfig.isNotEmpty) {
        final operationMode =
            chamberConfig['operation_mode']?.toString() == 'freeze'
            ? 'freeze'
            : 'refrigerate';

        final coolingLevel =
            int.tryParse(chamberConfig['cooling_level']?.toString() ?? '') ?? 4;

        final setpoint =
            double.tryParse(chamberConfig['setpoint']?.toString() ?? '') ??
            (operationMode == 'freeze'
                ? {
                    1: -12.0,
                    2: -14.0,
                    3: -16.0,
                    4: -18.0,
                    5: -20.0,
                    6: -22.0,
                    7: -24.0,
                  }[coolingLevel]!
                : {
                    1: 7.0,
                    2: 6.0,
                    3: 5.0,
                    4: 4.0,
                    5: 3.0,
                    6: 2.0,
                    7: 1.0,
                  }[coolingLevel]!);

        final differential =
            double.tryParse(chamberConfig['differential']?.toString() ?? '') ??
            (operationMode == 'freeze' ? 3.0 : 2.0);

        await _sendInitialConfiguration({
          'operation_mode': operationMode,
          'cooling_level': coolingLevel,
          'setpoint': setpoint,
          'differential': differential,
          'min_off_seconds':
              int.tryParse(
                chamberConfig['min_off_seconds']?.toString() ?? '',
              ) ??
              180,
          'temp_min_alarm':
              double.tryParse(
                chamberConfig['temp_min_alarm']?.toString() ?? '',
              ) ??
              (operationMode == 'freeze' ? setpoint - 4.0 : 0.0),
          'temp_max_alarm':
              double.tryParse(
                chamberConfig['temp_max_alarm']?.toString() ?? '',
              ) ??
              (setpoint + differential + 2.0),
        });
      } else {
        await _loadDeviceInfo();
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = 'Error configurando sensores: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  void _openInstallationTests() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => InstallationTestsPage(
          deviceInfo: _deviceInfo ?? {},
          initialConfiguration: _initialConfiguration ?? {},
        ),
      ),
    );
  }

  Future<void> _finishInstallation() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Finalizar instalación'),
          content: const Text(
            '¿Confirmas que el equipo fue probado y está listo para operar?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Finalizar'),
            ),
          ],
        );
      },
    );

    if (confirm != true) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final response = await http
          .post(Uri.parse('$_espBaseUrl/api/install/finish'))
          .timeout(const Duration(seconds: 12));

      final data = jsonDecode(response.body);

      if (response.statusCode != 200 || data['success'] != true) {
        throw Exception(data['error'] ?? 'No se pudo finalizar instalación');
      }

      if (!mounted) return;

      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          return AlertDialog(
            title: const Text('Instalación finalizada'),
            content: const Text(
              'El equipo quedó comisionado correctamente.\n\n'
              'El ESP se reiniciará y entrará en modo operativo.',
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Aceptar'),
              ),
            ],
          );
        },
      );

      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = 'Error finalizando instalación: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _sendInitialConfiguration(Map<String, dynamic> config) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final response = await http
          .post(
            Uri.parse('$_espBaseUrl/api/install/initial-config'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(config),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }

      final data = jsonDecode(response.body);

      if (data['success'] != true) {
        throw Exception(data['error'] ?? 'No se pudo guardar configuración');
      }

      await _loadDeviceInfo();

      if (!mounted) return;

      setState(() {
        _initialConfiguration = config;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = 'Error guardando configuración inicial: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final wifiConfigured = _deviceInfo?['wifi_configured'] == true;

    return Scaffold(
      backgroundColor: const Color(0xFF020B14),
      appBar: AppBar(
        title: const Text('Nueva instalación'),
        backgroundColor: const Color(0xFF061A2E),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Asistente de instalación',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Conecta el teléfono al AP del ESP y avanza paso a paso.',
            style: TextStyle(color: Color(0xFF9DB0C1)),
          ),
          const SizedBox(height: 18),

          if (_loading) const LinearProgressIndicator(),

          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],

          const SizedBox(height: 14),

          _InstallationActionCard(
            number: 1,
            title: 'Conectar dispositivo',
            subtitle: _deviceInfo == null
                ? 'Leer información del ESP.'
                : 'Dispositivo: $_deviceId',
            completed: _deviceInfo != null,
            buttonText: _deviceInfo == null ? 'Leer dispositivo' : 'Actualizar',
            onPressed: _loading ? null : _loadDeviceInfo,
          ),

          _InstallationActionCard(
            number: 2,
            title: 'Configurar WiFi',
            subtitle: wifiConfigured
                ? 'WiFi actual: ${_deviceInfo?['configured_wifi_ssid'] ?? _deviceInfo?['wifi_ssid'] ?? 'configurado'}'
                : 'Enviar SSID y clave al ESP.',
            completed: wifiConfigured,
            buttonText: wifiConfigured ? 'Cambiar WiFi' : 'Configurar WiFi',
            onPressed: _deviceInfo == null || _loading ? null : _scanWifi,
          ),

          _InstallationActionCard(
            number: 3,
            title: 'Sensores y funciones',
            subtitle: _deviceInfo?['sensors_assigned'] == true
                ? 'Sensores detectados y asignados.'
                : 'Detectar sondas DS18B20 y asignar roles.',
            completed: _deviceInfo?['sensors_assigned'] == true,
            buttonText: _deviceInfo?['sensors_assigned'] == true
                ? 'Cambiar sensores'
                : 'Configurar sensores',
            onPressed: _deviceInfo == null || _loading
                ? null
                : _detectAndAssignSensors,
          ),
          _InstallationActionCard(
            number: 4,
            title: 'Pruebas del equipo',
            subtitle: _deviceInfo?['parameters_configured'] == true
                ? 'Verificar lecturas, configuración y vista previa del cliente.'
                : 'Guarda primero la configuración inicial del equipo.',
            completed: false,
            buttonText: 'Abrir pruebas',
            onPressed:
                _deviceInfo == null ||
                    _loading ||
                    _deviceInfo?['sensors_assigned'] != true ||
                    _deviceInfo?['parameters_configured'] != true
                ? null
                : _openInstallationTests,
          ),
          _InstallationActionCard(
            number: 5,
            title: 'Finalizar instalación',
            subtitle: 'Comisionar el equipo y pasarlo a modo operativo.',
            completed: _deviceInfo?['installation_completed'] == true,
            buttonText: 'Finalizar instalación',
            onPressed:
                _deviceInfo == null ||
                    _loading ||
                    _deviceInfo?['wifi_configured'] != true ||
                    _deviceInfo?['sensors_assigned'] != true ||
                    _deviceInfo?['parameters_configured'] != true
                ? null
                : _finishInstallation,
          ),
        ],
      ),
    );
  }
}

class SmartColdMonitorView extends StatelessWidget {
  const SmartColdMonitorView({
    super.key,
    required this.data,
    required this.technicianMode,
  });

  final Map<String, dynamic> data;
  final bool technicianMode;

  @override
  Widget build(BuildContext context) {
    final deviceName =
        data['device_name'] ?? data['name'] ?? data['device_id'] ?? 'SmartCold';

    final coolingLevel =
        int.tryParse(data['cooling_level']?.toString() ?? '') ?? 4;
    final setpoint = double.tryParse(data['setpoint']?.toString() ?? '') ?? 0.0;
    final differential =
        double.tryParse(data['differential']?.toString() ?? '') ?? 0.0;

    final configuredSensorsRaw = data['configured_sensors'];
    final configuredSensors = configuredSensorsRaw is List
        ? configuredSensorsRaw
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList()
        : <Map<String, dynamic>>[];

    final defrostEnabled = data['defrost_enabled'] == true;
    final dripEnabled =
        defrostEnabled &&
        ((int.tryParse(data['drip_time_seconds']?.toString() ?? '') ?? 0) > 0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _HeroPanel(
          deviceName: deviceName,
          storeName: data['current_store_name'] ?? '',
          health: data['device_health'],
          healthReason: data['device_health_reason'],
          state: data['device_state'] ?? 'SETUP',
          online: true,
          rssi: data['rssi'],
          compressorOn: data['compressor_relay_on'],
          blockReason: data['compressor_block_reason'],
        ),

        const SizedBox(height: 8),

        _CoolingLevelDial(
          level: coolingLevel,
          setpoint: setpoint,
          turnOnTemp: setpoint + differential,
          turnOffTemp: setpoint,
          unlocked: false,
          onUnlockChanged: (_) {},
          onLevelChanged: (_) {},
        ),

        const SizedBox(height: 18),

        MonitorDynamicGrid(
          sensors: configuredSensors,
          data: data,
          technicianMode: technicianMode,
        ),
        if (defrostEnabled || dripEnabled) ...[
          const SizedBox(height: 12),

          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (defrostEnabled)
                  Expanded(
                    child: _DefrostCard(
                      active: data['defrost_active'],
                      evaporatorTemp: null,
                      chamberTemp: null,
                      endTemperature: data['defrost_end_temperature'],
                      remainingSeconds: data['defrost_remaining_seconds'],
                      nextSeconds: data['defrost_next_seconds'],
                      durationMinutes: data['defrost_duration_minutes'],
                      intervalMinutes: data['defrost_interval_minutes'],
                      connectionStatus: 'online',
                      secondsSinceLastSeen: 0,
                    ),
                  ),

                if (defrostEnabled && dripEnabled) const SizedBox(width: 8),

                if (dripEnabled)
                  Expanded(
                    child: _DripCard(
                      active: data['drip_active'],
                      configuredSeconds: data['drip_time_seconds'],
                      remainingSeconds: data['drip_remaining_seconds'],
                      connectionStatus: 'online',
                      secondsSinceLastSeen: 0,
                    ),
                  ),
              ],
            ),
          ),
        ],

        if (technicianMode) ...[
          const SizedBox(height: 18),
          Card(
            color: const Color(0xFF061A2E),
            child: ListTile(
              leading: const Icon(
                Icons.engineering_rounded,
                color: Color(0xFF00A8FF),
              ),
              title: const Text(
                'Modo técnico',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
              ),
              subtitle: const Text(
                'Aquí agregaremos pruebas de salidas, sensores y diagnóstico.',
                style: TextStyle(color: Color(0xFF9DB0C1)),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class MonitorDynamicGrid extends StatelessWidget {
  const MonitorDynamicGrid({
    super.key,
    required this.sensors,
    required this.data,
    required this.technicianMode,
  });

  final List<Map<String, dynamic>> sensors;
  final Map<String, dynamic> data;
  final bool technicianMode;

  Widget _sensorCard(Map<String, dynamic> sensor) {
    final name = sensor['name']?.toString() ?? 'Sensor';
    final hasReading = sensor['has_reading'] == true;
    final temperature = hasReading ? sensor['temperature'] : null;

    final alarmEnabled = sensor['alarm_enabled'] == true;
    final canStopCompressor = sensor['can_stop_compressor'] == true;
    final tempMin = double.tryParse(sensor['temp_min_alarm']?.toString() ?? '');
    final tempMax = double.tryParse(sensor['temp_max_alarm']?.toString() ?? '');
    final tempValue = double.tryParse(temperature?.toString() ?? '');

    bool inAlarm = false;
    String badge = hasReading ? 'NORMAL' : 'SIN LECTURA';

    if (canStopCompressor && hasReading) {
      badge = technicianMode ? 'PROTEGE' : 'NORMAL';
    }

    if (hasReading && alarmEnabled && tempValue != null) {
      if (tempMax != null && tempValue > tempMax) {
        inAlarm = true;
        badge = canStopCompressor
            ? (technicianMode ? 'BLOQUEO ALTA' : 'PROTECCIÓN')
            : (technicianMode ? 'ALTA' : 'ALERTA');
      } else if (tempMin != null && tempValue < tempMin) {
        inAlarm = true;
        badge = canStopCompressor
            ? (technicianMode ? 'BLOQUEO BAJA' : 'PROTECCIÓN')
            : (technicianMode ? 'BAJA' : 'ALERTA');
      }
    }

    return _KpiCard(
      title: name,
      value: temperature,
      suffix: '°C',
      icon: Icons.thermostat_rounded,
      badgeText: badge,
      accent: inAlarm ? Colors.redAccent : const Color(0xFF1EA7FF),
    );
  }

  Widget _compressorCard() {
    return _MiniCompressorKpi(
      relayOn: data['compressor_relay_on'],
      shouldBeOn: data['compressor_should_be_on'],
      protectionSeconds: data['compressor_wait_seconds_remaining'],
      connectionStatus: 'online',
      secondsSinceLastSeen: 0,
    );
  }

  Widget _row(List<Widget> children) {
    return SizedBox(
      height: 132,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (int i = 0; i < children.length; i++) ...[
            Expanded(child: children[i]),
            if (i < children.length - 1) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final orderedSensors = [...sensors];

    orderedSensors.sort((a, b) {
      final ar = a['role']?.toString() ?? '';
      final br = b['role']?.toString() ?? '';

      int weight(String role) {
        if (role == 'chamber') return 0;
        if (role == 'evaporator') return 1;
        return 2;
      }

      return weight(ar).compareTo(weight(br));
    });

    final sensorCards = orderedSensors.map(_sensorCard).toList();
    final compressor = _compressorCard();

    final rows = <Widget>[];

    if (sensorCards.isEmpty) {
      rows.add(_row([compressor]));
    } else if (sensorCards.length == 1) {
      rows.add(_row([sensorCards[0], compressor]));
    } else if (sensorCards.length == 2) {
      rows.add(_row([sensorCards[0], sensorCards[1], compressor]));
    } else if (sensorCards.length == 3) {
      rows.add(_row([sensorCards[0], compressor]));
      rows.add(_row([sensorCards[1], sensorCards[2]]));
    } else {
      rows.add(_row([sensorCards[0], sensorCards[1], compressor]));

      for (int i = 2; i < sensorCards.length; i += 2) {
        final remaining = sensorCards.skip(i).take(2).toList();
        rows.add(_row(remaining));
      }
    }

    return Column(
      children: [
        for (int i = 0; i < rows.length; i++) ...[
          rows[i],
          if (i < rows.length - 1) const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class InstallationTestsPage extends StatefulWidget {
  const InstallationTestsPage({
    super.key,
    required this.deviceInfo,
    required this.initialConfiguration,
  });

  final Map<String, dynamic> deviceInfo;
  final Map<String, dynamic> initialConfiguration;

  @override
  State<InstallationTestsPage> createState() => _InstallationTestsPageState();
}

class _InstallationTestsPageState extends State<InstallationTestsPage> {
  static const String _espBaseUrl = 'http://192.168.4.1';

  bool _loading = false;
  Timer? _refreshTimer;
  String? _error;
  Map<String, dynamic> _deviceInfo = {};

  @override
  void initState() {
    super.initState();
    _deviceInfo = Map<String, dynamic>.from(widget.deviceInfo);
    _refreshDeviceInfo();
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted && !_loading) {
        _refreshDeviceInfo();
      }
    });
  }

  Future<void> _refreshDeviceInfo() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final response = await http
          .get(Uri.parse('$_espBaseUrl/api/device-info'))
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final data = jsonDecode(response.body);

      if (!mounted) return;

      setState(() {
        _deviceInfo = Map<String, dynamic>.from(data);
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = 'No se pudo actualizar información del ESP: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF020B14),
      appBar: AppBar(
        title: const Text('Pruebas del equipo'),
        backgroundColor: const Color(0xFF061A2E),
        actions: [
          IconButton(
            tooltip: 'Actualizar',
            onPressed: _loading ? null : _refreshDeviceInfo,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_loading) const LinearProgressIndicator(),

          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],

          const SizedBox(height: 12),

          SmartColdMonitorView(data: _deviceInfo, technicianMode: true),
        ],
      ),
    );
  }
}

class _InstallationActionCard extends StatelessWidget {
  const _InstallationActionCard({
    required this.number,
    required this.title,
    required this.subtitle,
    required this.completed,
    required this.buttonText,
    required this.onPressed,
  });

  final int number;
  final String title;
  final String subtitle;
  final bool completed;
  final String buttonText;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF061A2E),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: completed
                      ? const Color(0xFF20D76D)
                      : const Color(0xFF00A8FF),
                  child: completed
                      ? const Icon(Icons.check_rounded, color: Colors.white)
                      : Text(
                          '$number',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(subtitle, style: const TextStyle(color: Color(0xFF9DB0C1))),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: onPressed,
                child: Text(buttonText),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WifiConfigSheet extends StatefulWidget {
  const _WifiConfigSheet({required this.networks});

  final List<Map<String, dynamic>> networks;

  @override
  State<_WifiConfigSheet> createState() => _WifiConfigSheetState();
}

class _WifiConfigSheetState extends State<_WifiConfigSheet> {
  final _passwordController = TextEditingController();

  String? _selectedSsid;
  String? _error;
  bool _showPassword = false;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    final password = _passwordController.text.trim();

    if (_selectedSsid == null || _selectedSsid!.isEmpty) {
      setState(() {
        _error = 'Selecciona una red WiFi';
      });
      return;
    }

    if (password.isEmpty) {
      setState(() {
        _error = 'Ingresa la contraseña WiFi';
      });
      return;
    }

    Navigator.pop(context, {'ssid': _selectedSsid!, 'password': password});
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Configurar WiFi',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 14),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Redes detectadas',
                style: TextStyle(
                  color: Color(0xFF9DB0C1),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(height: 8),
            ...widget.networks.map((network) {
              final ssid = network['ssid']?.toString() ?? '';
              final rssi = network['rssi']?.toString() ?? '—';
              final selected = _selectedSsid == ssid;

              return Card(
                color: const Color(0xFF061A2E),
                child: ListTile(
                  leading: Icon(
                    selected ? Icons.check_circle_rounded : Icons.wifi_rounded,
                    color: const Color(0xFF00A8FF),
                  ),
                  title: Text(
                    ssid.isEmpty ? 'Red sin nombre' : ssid,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  subtitle: Text(
                    'Señal: $rssi dBm',
                    style: const TextStyle(color: Color(0xFF9DB0C1)),
                  ),
                  onTap: () {
                    setState(() {
                      _selectedSsid = ssid;
                      _error = null;
                    });
                  },
                ),
              );
            }),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              obscureText: !_showPassword,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Contraseña',
                prefixIcon: const Icon(Icons.lock_rounded),
                suffixIcon: IconButton(
                  icon: Icon(
                    _showPassword
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                  ),
                  onPressed: () {
                    setState(() {
                      _showPassword = !_showPassword;
                    });
                  },
                ),
                border: const OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _submit,
                icon: const Icon(Icons.send_rounded),
                label: const Text('Enviar al dispositivo'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AssignSensorRolesSheet extends StatefulWidget {
  const _AssignSensorRolesSheet({
    required this.sensors,
    required this.initialSensors,
    required this.initialOperationMode,
    required this.initialCoolingLevel,
  });

  final List<Map<String, dynamic>> sensors;
  final Map<String, Map<String, dynamic>> initialSensors;
  final String initialOperationMode;
  final int initialCoolingLevel;

  @override
  State<_AssignSensorRolesSheet> createState() =>
      _AssignSensorRolesSheetState();
}

class _AssignSensorRolesSheetState extends State<_AssignSensorRolesSheet> {
  late Map<String, Map<String, dynamic>> _sensorsByAddress;
  String? _error;
  late String _operationMode;
  late int _coolingLevel;
  final List<Map<String, String>> _availableRoles = const [
    {'value': '', 'label': 'Sin asignar'},
    {'value': 'chamber', 'label': 'Cámara'},
    {'value': 'evaporator', 'label': 'Evaporador'},
    {'value': 'condenser', 'label': 'Condensador'},
    {'value': 'compressor', 'label': 'Compresor'},
    {'value': 'ambient', 'label': 'Ambiente'},
    {'value': 'aux1', 'label': 'Auxiliar 1'},
    {'value': 'aux2', 'label': 'Auxiliar 2'},
    {'value': 'aux3', 'label': 'Auxiliar 3'},
  ];

  double _toDouble(dynamic value, double fallback) {
    if (value == null) return fallback;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? fallback;
  }

  bool _toBool(dynamic value, bool fallback) {
    if (value == null) return fallback;
    if (value is bool) return value;
    return fallback;
  }

  bool _isProtectionRole(String role) {
    return role == 'evaporator' || role == 'condenser' || role == 'compressor';
  }

  bool _isMonitoringRole(String role) {
    return role == 'ambient' ||
        role == 'aux1' ||
        role == 'aux2' ||
        role == 'aux3';
  }

  bool get _isFreezer => _operationMode == 'freeze';

  double get _setpoint {
    if (_isFreezer) {
      return {
        1: -12.0,
        2: -14.0,
        3: -16.0,
        4: -18.0,
        5: -20.0,
        6: -22.0,
        7: -24.0,
      }[_coolingLevel]!;
    }

    return {
      1: 7.0,
      2: 6.0,
      3: 5.0,
      4: 4.0,
      5: 3.0,
      6: 2.0,
      7: 1.0,
    }[_coolingLevel]!;
  }

  double get _differential => _isFreezer ? 3.0 : 2.0;

  double get _turnOnTemperature => _setpoint + _differential;

  double get _tempMaxAlarm => _turnOnTemperature + 2.0;

  double get _tempMinAlarm {
    if (_isFreezer) {
      return _setpoint - 4.0;
    }

    return (_setpoint - 4.0) < 0 ? 0.0 : _setpoint - 4.0;
  }

  int get _minOffSeconds => 180;

  Map<String, dynamic> _calculatedMainControlConfig() {
    return {
      'operation_mode': _operationMode,
      'cooling_level': _coolingLevel,
      'setpoint': _setpoint,
      'differential': _differential,
      'min_off_seconds': _minOffSeconds,
      'temp_min_alarm': _tempMinAlarm,
      'temp_max_alarm': _tempMaxAlarm,
    };
  }

  void _applyDefaultsForRole(Map<String, dynamic> item, String role) {
    item['role'] = role;
    item['name'] = _defaultNameForRole(role);
    item['enabled'] = role.isNotEmpty;

    if (role == 'chamber') {
      item['alarm_enabled'] = false;
      item['can_stop_compressor'] = true;
      item['temp_min_alarm'] = item['temp_min_alarm'] ?? 0;
      item['temp_max_alarm'] = item['temp_max_alarm'] ?? 8;
      return;
    }

    if (role == 'evaporator') {
      item['alarm_enabled'] = true;
      item['temp_min_alarm'] = item['temp_min_alarm'] ?? -20;
      item['temp_max_alarm'] = item['temp_max_alarm'] ?? 30;
      item['can_stop_compressor'] = item['can_stop_compressor'] ?? false;
      item['defrost_enabled'] = item['defrost_enabled'] ?? false;
      item['defrost_interval_minutes'] =
          item['defrost_interval_minutes'] ?? 240;
      item['defrost_duration_minutes'] = item['defrost_duration_minutes'] ?? 20;
      item['defrost_end_by_temperature'] =
          item['defrost_end_by_temperature'] ?? true;
      item['defrost_end_temperature'] = item['defrost_end_temperature'] ?? 8;
      item['drip_time_seconds'] = item['drip_time_seconds'] ?? 120;
      return;
    }

    if (role == 'condenser') {
      item['alarm_enabled'] = true;
      item['temp_min_alarm'] = item['temp_min_alarm'] ?? -100;
      item['temp_max_alarm'] = item['temp_max_alarm'] ?? 60;
      item['can_stop_compressor'] = item['can_stop_compressor'] ?? true;
      return;
    }

    if (role == 'compressor') {
      item['alarm_enabled'] = true;
      item['temp_min_alarm'] = item['temp_min_alarm'] ?? -100;
      item['temp_max_alarm'] = item['temp_max_alarm'] ?? 90;
      item['can_stop_compressor'] = item['can_stop_compressor'] ?? true;
      return;
    }

    if (_isMonitoringRole(role)) {
      item['alarm_enabled'] = true;
      item['temp_min_alarm'] = item['temp_min_alarm'] ?? -100;
      item['temp_max_alarm'] = item['temp_max_alarm'] ?? 100;
      item['can_stop_compressor'] = false;
    }
  }

  Widget _numberField({
    required String label,
    required dynamic value,
    required ValueChanged<double> onChanged,
  }) {
    final controller = TextEditingController(
      text: _toDouble(value, 0).toString(),
    );

    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
      onChanged: (text) {
        final parsed = double.tryParse(text.replaceAll(',', '.'));
        if (parsed != null) {
          onChanged(parsed);
        }
      },
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _advancedSensorConfig(String address, Map<String, dynamic> item) {
    final role = item['role']?.toString() ?? '';

    if (role.isEmpty) {
      return const SizedBox.shrink();
    }
    final canStopCompressor = _toBool(item['can_stop_compressor'], false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 14),
        const Divider(),
        const SizedBox(height: 8),

        Text(
          role == 'chamber' ? 'Configuración cámara' : 'Configuración avanzada',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
          ),
        ),

        const SizedBox(height: 10),

        _numberField(
          label: 'Offset / calibración °C',
          value: item['offset'] ?? 0,
          onChanged: (value) {
            item['offset'] = value;
          },
        ),

        if (role == 'chamber') ...[
          const SizedBox(height: 14),

          const Text(
            'Modo de trabajo',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),

          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'refrigerate',
                label: Text('Refrigerador'),
                icon: Icon(Icons.kitchen_rounded),
              ),
              ButtonSegment(
                value: 'freeze',
                label: Text('Congelador'),
                icon: Icon(Icons.ac_unit_rounded),
              ),
            ],
            selected: {_operationMode},
            onSelectionChanged: (values) {
              setState(() {
                _operationMode = values.first;
              });
            },
          ),

          const SizedBox(height: 18),

          const Text(
            'Nivel de frío',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900),
          ),

          Slider(
            value: _coolingLevel.toDouble(),
            min: 1,
            max: 7,
            divisions: 6,
            label: _coolingLevel.toString(),
            onChanged: (value) {
              setState(() {
                _coolingLevel = value.round();
              });
            },
          ),

          Text(
            'Nivel $_coolingLevel de 7',
            style: const TextStyle(color: Color(0xFF9DB0C1)),
          ),

          const SizedBox(height: 14),

          Card(
            color: const Color(0xFF020B14),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Configuración calculada',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Setpoint: ${_setpoint.toStringAsFixed(1)} °C',
                    style: const TextStyle(color: Color(0xFF9DB0C1)),
                  ),
                  Text(
                    'Enciende: ${_turnOnTemperature.toStringAsFixed(1)} °C',
                    style: const TextStyle(color: Color(0xFF9DB0C1)),
                  ),
                  Text(
                    'Apaga: ${_setpoint.toStringAsFixed(1)} °C',
                    style: const TextStyle(color: Color(0xFF9DB0C1)),
                  ),
                  Text(
                    'Alarma baja: ${_tempMinAlarm.toStringAsFixed(1)} °C',
                    style: const TextStyle(color: Color(0xFF9DB0C1)),
                  ),
                  Text(
                    'Alarma alta: ${_tempMaxAlarm.toStringAsFixed(1)} °C',
                    style: const TextStyle(color: Color(0xFF9DB0C1)),
                  ),
                  Text(
                    'Protección compresor: $_minOffSeconds segundos',
                    style: const TextStyle(color: Color(0xFF9DB0C1)),
                  ),
                ],
              ),
            ),
          ),
        ],

        if (role != 'chamber') ...[
          const SizedBox(height: 10),

          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _numberField(
                  label: 'Alarma mínima °C',
                  value: item['temp_min_alarm'],
                  onChanged: (value) {
                    item['temp_min_alarm'] = value;
                    item['alarm_enabled'] = true;
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _numberField(
                  label: 'Alarma máxima °C',
                  value: item['temp_max_alarm'],
                  onChanged: (value) {
                    item['temp_max_alarm'] = value;
                    item['alarm_enabled'] = true;
                  },
                ),
              ),
            ],
          ),

          if (_isProtectionRole(role)) ...[
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Puede detener compresor',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
              subtitle: Text(
                role == 'evaporator'
                    ? 'Útil para proteger por evaporador congelado.'
                    : role == 'condenser'
                    ? 'Útil por condensador muy caliente.'
                    : 'Útil por compresor sobrecalentado.',
                style: const TextStyle(color: Color(0xFF9DB0C1)),
              ),
              value: canStopCompressor,
              onChanged: (value) {
                setState(() {
                  item['can_stop_compressor'] = value;
                });
              },
            ),
          ],
          if (role == 'evaporator') ...[
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Activar defrost',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
              subtitle: const Text(
                'El evaporador controlará el deshielo y el tiempo de goteo.',
                style: TextStyle(color: Color(0xFF9DB0C1)),
              ),
              value: item['defrost_enabled'] == true,
              onChanged: (value) {
                setState(() {
                  item['defrost_enabled'] = value;
                  item['defrost_interval_minutes'] ??= 240;
                  item['defrost_duration_minutes'] ??= 20;
                  item['defrost_end_by_temperature'] ??= true;
                  item['defrost_end_temperature'] ??= 8;
                  item['drip_time_seconds'] ??= 120;
                });
              },
            ),

            if (item['defrost_enabled'] == true) ...[
              const SizedBox(height: 10),
              const Divider(),
              const SizedBox(height: 8),
              const Text(
                'Parámetros de defrost',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 10),
              _numberField(
                label: 'Intervalo entre deshielos min (30-1440)',
                value: item['defrost_interval_minutes'],
                onChanged: (value) {
                  item['defrost_interval_minutes'] = value.round();
                },
              ),

              const SizedBox(height: 10),

              _numberField(
                label: 'Duración máxima min (2-60)',
                value: item['defrost_duration_minutes'],
                onChanged: (value) {
                  item['defrost_duration_minutes'] = value.round();
                },
              ),
              const SizedBox(height: 8),
              _numberField(
                label: 'Temperatura fin defrost °C',
                value: item['defrost_end_temperature'],
                onChanged: (value) {
                  item['defrost_end_temperature'] = value;
                },
              ),

              const SizedBox(height: 10),

              _numberField(
                label: 'Tiempo de goteo seg (10-600)',
                value: item['drip_time_seconds'],
                onChanged: (value) {
                  item['drip_time_seconds'] = value.round();
                },
              ),
            ],
          ],
          if (_isMonitoringRole(role)) ...[
            const SizedBox(height: 8),
            const Text(
              'Este sensor queda como monitoreo/advertencia. No detiene el compresor.',
              style: TextStyle(color: Color(0xFF9DB0C1), fontSize: 12),
            ),
          ],
        ],
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    _operationMode = widget.initialOperationMode;
    _coolingLevel = widget.initialCoolingLevel;
    _sensorsByAddress = Map<String, Map<String, dynamic>>.from(
      widget.initialSensors,
    );

    for (final sensor in widget.sensors) {
      final address = sensor['address']?.toString() ?? '';
      if (address.isEmpty) continue;

      _sensorsByAddress.putIfAbsent(address, () {
        return {
          'id': sensor['id']?.toString() ?? '',
          'type': sensor['type']?.toString() ?? 'ds18b20',
          'role': sensor['role']?.toString() ?? '',
          'name': sensor['name']?.toString() ?? 'Sin asignar',
          'address': address,
          'enabled': sensor['configured'] == true,
          'offset': sensor['offset'] ?? 0,
          'alarm_enabled': sensor['alarm_enabled'] ?? false,
          'temp_min_alarm': sensor['temp_min_alarm'] ?? -100,
          'temp_max_alarm': sensor['temp_max_alarm'] ?? 100,
          'can_stop_compressor': sensor['can_stop_compressor'] ?? false,
        };
      });
    }
  }

  String _defaultNameForRole(String role) {
    switch (role) {
      case 'chamber':
        return 'Cámara';
      case 'evaporator':
        return 'Evaporador';
      case 'condenser':
        return 'Condensador';
      case 'compressor':
        return 'Compresor';
      case 'ambient':
        return 'Ambiente';
      case 'aux1':
        return 'Auxiliar 1';
      case 'aux2':
        return 'Auxiliar 2';
      case 'aux3':
        return 'Auxiliar 3';
      default:
        return 'Sin asignar';
    }
  }

  void _submit() {
    Map<String, dynamic> normalizeSensor(Map<String, dynamic> sensor) {
      final normalized = Map<String, dynamic>.from(sensor);

      normalized['alarm_enabled'] = true;

      if (normalized['role']?.toString() == 'chamber') {
        normalized['temp_min_alarm'] = _tempMinAlarm;
        normalized['temp_max_alarm'] = _tempMaxAlarm;
        normalized['can_stop_compressor'] = true;
        normalized.addAll(_calculatedMainControlConfig());
      }

      if (normalized['role']?.toString() == 'evaporator') {
        normalized['defrost_enabled'] = normalized['defrost_enabled'] == true;

        normalized['defrost_interval_minutes'] = (_toDouble(
          normalized['defrost_interval_minutes'],
          240,
        )).clamp(30, 1440).round();

        normalized['defrost_duration_minutes'] = (_toDouble(
          normalized['defrost_duration_minutes'],
          20,
        )).clamp(2, 60).round();

        normalized['defrost_end_by_temperature'] = true;

        normalized['defrost_end_temperature'] = (_toDouble(
          normalized['defrost_end_temperature'],
          8,
        )).clamp(-10, 25).toDouble();

        normalized['drip_time_seconds'] = (_toDouble(
          normalized['drip_time_seconds'],
          120,
        )).clamp(10, 600).round();
      }

      return normalized;
    }

    final selected = _sensorsByAddress.values.where((sensor) {
      final role = sensor['role']?.toString() ?? '';
      return role.isNotEmpty;
    }).toList();

    final hasChamber = selected.any(
      (sensor) => sensor['role']?.toString() == 'chamber',
    );

    if (!hasChamber) {
      setState(() {
        _error = 'Debes asignar una sonda como Cámara para continuar.';
      });
      return;
    }
    for (final sensor in selected) {
      if (sensor['role']?.toString() == 'evaporator' &&
          sensor['defrost_enabled'] == true) {
        final interval = _toDouble(
          sensor['defrost_interval_minutes'],
          240,
        ).round();
        final duration = _toDouble(
          sensor['defrost_duration_minutes'],
          20,
        ).round();
        final endTemp = _toDouble(sensor['defrost_end_temperature'], 8);
        final drip = _toDouble(sensor['drip_time_seconds'], 120).round();

        if (interval < 30 || interval > 1440) {
          setState(() {
            _error =
                'El intervalo de defrost debe estar entre 30 y 1440 minutos.';
          });
          return;
        }

        if (duration < 2 || duration > 60) {
          setState(() {
            _error = 'La duración del defrost debe estar entre 2 y 60 minutos.';
          });
          return;
        }

        if (endTemp < -10 || endTemp > 25) {
          setState(() {
            _error =
                'La temperatura de finalización debe estar entre -10 °C y 25 °C.';
          });
          return;
        }

        if (drip < 10 || drip > 600) {
          setState(() {
            _error = 'El tiempo de goteo debe estar entre 10 y 600 segundos.';
          });
          return;
        }
      }
    }
    Navigator.pop(context, {
      for (final sensor in selected)
        sensor['address'].toString(): normalizeSensor(sensor),
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            const Text(
              'Asignar roles de sondas',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 12),
            ...widget.sensors.map((sensor) {
              final address = sensor['address']?.toString() ?? '';
              final current = _sensorsByAddress[address] ?? {};
              final selectedRole = current['role']?.toString();
              final nameController = TextEditingController(
                text: current['name']?.toString() ?? '',
              );

              return Card(
                color: const Color(0xFF061A2E),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        address,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Temperatura: ${sensor['temperature'] ?? '—'} °C',
                        style: const TextStyle(color: Color(0xFF9DB0C1)),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: selectedRole != null && selectedRole.isNotEmpty
                              ? selectedRole
                              : null,
                          hint: const Text(
                            'Seleccionar rol',
                            style: TextStyle(color: Color(0xFF9DB0C1)),
                          ),
                          dropdownColor: const Color(0xFF061A2E),
                          isExpanded: true,
                          items: _availableRoles.map((role) {
                            return DropdownMenuItem<String>(
                              value: role['value'],
                              child: Text(
                                role['label'] ?? '',
                                style: const TextStyle(color: Colors.white),
                              ),
                            );
                          }).toList(),
                          onChanged: (value) {
                            if (value == null) return;

                            setState(() {
                              _error = null;
                              if ([
                                'chamber',
                                'evaporator',
                                'condenser',
                                'compressor',
                                'ambient',
                              ].contains(value)) {
                                _sensorsByAddress.forEach((key, item) {
                                  if (item['role'] == value) {
                                    item['role'] = '';
                                    item['name'] = 'Sin asignar';
                                    item['enabled'] = false;
                                  }
                                });
                              }

                              final item = _sensorsByAddress[address]!;

                              if (value.isEmpty) {
                                item['role'] = '';
                                item['name'] = 'Sin asignar';
                                item['enabled'] = false;
                                item['alarm_enabled'] = false;
                                item['can_stop_compressor'] = false;
                              } else {
                                _applyDefaultsForRole(item, value);
                              }
                            });
                          },
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: nameController,
                        onChanged: (value) {
                          _sensorsByAddress[address]?['name'] = value.trim();
                        },
                        decoration: const InputDecoration(
                          labelText: 'Nombre visible',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      _advancedSensorConfig(address, current),
                    ],
                  ),
                ),
              );
            }),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.redAccent,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _submit,
                icon: const Icon(Icons.check_rounded),
                label: const Text('Guardar sensores'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ContinueInstallationPage extends StatelessWidget {
  const ContinueInstallationPage({
    super.key,
    required this.installationId,
    required this.installationData,
  });

  final String installationId;
  final Map<String, dynamic> installationData;

  @override
  Widget build(BuildContext context) {
    final deviceId =
        installationData['device_id']?.toString() ?? 'Sin device_id';
    final phase = installationData['phase']?.toString() ?? 'Fase desconocida';
    final status =
        installationData['status']?.toString() ?? 'Estado desconocido';

    return Scaffold(
      backgroundColor: const Color(0xFF020B14),
      appBar: AppBar(
        title: const Text('Continuar instalación'),
        backgroundColor: const Color(0xFF061A2E),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _AccountInfoTile(
            icon: Icons.memory_rounded,
            title: 'Dispositivo',
            value: deviceId,
          ),
          _AccountInfoTile(
            icon: Icons.timeline_rounded,
            title: 'Fase actual',
            value: phase,
          ),
          _AccountInfoTile(
            icon: Icons.info_rounded,
            title: 'Estado',
            value: status,
          ),
        ],
      ),
    );
  }
}

class InstallationWizardPage extends StatelessWidget {
  const InstallationWizardPage({super.key, required this.installationId});

  final String installationId;

  @override
  Widget build(BuildContext context) {
    final installationRef = FirebaseFirestore.instance
        .collection('installations')
        .doc(installationId);

    return Scaffold(
      backgroundColor: const Color(0xFF020B14),
      appBar: AppBar(
        title: const Text('Asistente de instalación'),
        backgroundColor: const Color(0xFF061A2E),
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: installationRef.snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(
              child: Text(
                'Error cargando instalación',
                style: TextStyle(color: Colors.white),
              ),
            );
          }

          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final data = snapshot.data!.data();

          if (data == null) {
            return const Center(
              child: Text(
                'Instalación no encontrada',
                style: TextStyle(color: Colors.white),
              ),
            );
          }

          final deviceId = data['device_id']?.toString() ?? 'Sin device_id';
          final phase = data['phase']?.toString() ?? 'Sin fase';
          final status = data['status']?.toString() ?? 'Sin estado';

          final wifiConfigured = data['wifi_configured'] == true;
          final sensorsDetected = data['sensors_detected'] == true;
          final sensorsAssigned = data['sensors_assigned'] == true;
          final parametersConfigured = data['parameters_configured'] == true;
          final testsCompleted = data['tests_completed'] == true;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _AccountInfoTile(
                icon: Icons.memory_rounded,
                title: 'Dispositivo',
                value: deviceId,
              ),
              _AccountInfoTile(
                icon: Icons.timeline_rounded,
                title: 'Fase actual',
                value: phase,
              ),
              _AccountInfoTile(
                icon: Icons.info_rounded,
                title: 'Estado',
                value: status,
              ),
              const SizedBox(height: 18),
              const Text(
                'Progreso de instalación',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 10),
              _InstallationStepTile(
                number: 1,
                title: 'WiFi configurado',
                subtitle: wifiConfigured
                    ? 'El dispositivo ya tiene WiFi configurado.'
                    : 'Pendiente configurar WiFi.',
                completed: wifiConfigured,
              ),
              _InstallationStepTile(
                number: 2,
                title: 'Sensores detectados',
                subtitle: sensorsDetected
                    ? 'El dispositivo ya detectó sensores.'
                    : 'Pendiente detectar sensores.',
                completed: sensorsDetected,
              ),
              _InstallationStepTile(
                number: 3,
                title: 'Roles de sensores',
                subtitle: sensorsAssigned
                    ? 'Los sensores ya tienen roles asignados.'
                    : 'Pendiente asignar roles.',
                completed: sensorsAssigned,
                onTap: () async {
                  final detectedSensorsRaw = data['detected_sensors'];

                  final sensors = detectedSensorsRaw is List
                      ? detectedSensorsRaw
                            .map((item) => item.toString())
                            .toList()
                      : <String>[];

                  if (sensors.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'No hay sensores detectados para asignar.',
                        ),
                      ),
                    );
                    return;
                  }

                  final result =
                      await showModalBottomSheet<Map<String, String>>(
                        context: context,
                        isScrollControlled: true,
                        backgroundColor: const Color(0xFF020B14),
                        builder: (context) {
                          return _AssignSensorRolesSheet(
                            sensors: sensors
                                .map(
                                  (address) => {
                                    'address': address,
                                    'type': 'ds18b20',
                                    'temperature': null,
                                    'configured': false,
                                  },
                                )
                                .toList(),
                            initialSensors: {},
                            initialOperationMode: 'refrigerate',
                            initialCoolingLevel: 4,
                          );
                        },
                      );

                  if (result == null) return;

                  await installationRef.update({
                    'sensor_roles': result,
                    'sensors_assigned': true,
                    'phase': 'pending_parameters',
                    'updated_at': FieldValue.serverTimestamp(),
                  });
                },
              ),
              _InstallationStepTile(
                number: 4,
                title: 'Parámetros',
                subtitle: parametersConfigured
                    ? 'Parámetros configurados.'
                    : 'Pendiente configurar parámetros.',
                completed: parametersConfigured,
              ),
              _InstallationStepTile(
                number: 5,
                title: 'Pruebas',
                subtitle: testsCompleted
                    ? 'Pruebas completadas.'
                    : 'Pendiente realizar pruebas.',
                completed: testsCompleted,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _InstallationStepTile extends StatelessWidget {
  const _InstallationStepTile({
    required this.number,
    required this.title,
    required this.subtitle,
    required this.completed,
    this.onTap,
  });

  final int number;
  final String title;
  final String subtitle;
  final bool completed;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF061A2E),
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: completed
              ? const Color(0xFF20D76D)
              : const Color(0xFF00A8FF),
          child: completed
              ? const Icon(Icons.check_rounded, color: Colors.white)
              : Text(
                  '$number',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                ),
        ),
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: const TextStyle(color: Color(0xFF9DB0C1)),
        ),
      ),
    );
  }
}
