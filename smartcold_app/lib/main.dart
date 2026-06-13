import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:wifi_scan/wifi_scan.dart';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:wifi_iot/wifi_iot.dart';

import 'firebase_options.dart';

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

    if (role == 'admin' && _selectedClientId != null) {
      devicesQuery = devicesQuery.where(
        'current_client_id',
        isEqualTo: _selectedClientId,
      );
    }
    if (role == 'admin' && _selectedStoreId != null) {
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
    final type = deviceData['type']?.toString() ?? 'Equipo';
    final storeName =
        deviceData['store_name']?.toString() ??
        deviceData['current_store_id']?.toString() ??
        'Tienda sin nombre';

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: statusRef.snapshots(),
      builder: (context, snapshot) {
        final statusData = snapshot.data?.data();

        final state = statusData?['device_state']?.toString() ?? 'SIN DATOS';
        final health = statusData?['device_health']?.toString() ?? 'UNKNOWN';
        final healthReason =
            statusData?['device_health_reason']?.toString() ?? '';
        final chamberTemp = _readSensor(statusData, 'chamber');
        final seconds = _secondsSinceLastSeen(statusData?['last_seen_at']);
        final connection = _connectionStatus(seconds);

        final isOffline = connection == 'offline';
        final hasWarning = health == 'WARNING' || health == 'ERROR';

        final color = isOffline
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
                            Text(
                              '$storeName · $type',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFF9DB0C1),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
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
                          value: _stateLabel(state),
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

  @override
  void initState() {
    super.initState();
    _loadConfigSummary();

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadConfigSummary({bool lockDial = false}) async {
    try {
      final response = await http.get(
        Uri.parse(
          'https://smartcold-api-649501100610.us-central1.run.app/api/devices/${widget.deviceId}/config-summary',
        ),
      );

      if (response.statusCode != 200) return;

      final body = jsonDecode(response.body);

      if (body['success'] != true) return;

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
      // Sin bloqueo visual si la API no responde.
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusRef = FirebaseFirestore.instance
        .collection('device_status')
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

              final setpoint = _configSetpoint ?? 0.0;
              final turnOnTemp = _configTurnOnTemp ?? 0.0;
              final turnOffTemp = _configTurnOffTemp ?? 0.0;

              final secondsSinceLastSeen = _secondsSinceLastSeen(
                data['last_seen_at'],
              );

              final connectionStatus = _connectionStatus(secondsSinceLastSeen);

              final lastUpdateText = _lastUpdateText(secondsSinceLastSeen);

              final chamberTemp = _sensorValue(data, 'chamber');
              final evaporatorTemp = _sensorValue(data, 'evaporator');

              return Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
                      children: [
                        _TopBar(
                          connectionStatus: connectionStatus,
                          rssi: data['rssi'],
                        ),
                        const SizedBox(height: 14),

                        _HeroPanel(
                          deviceName:
                              data['device_name'] ??
                              data['name'] ??
                              widget.deviceId,
                          health: data['device_health'],
                          healthReason: data['device_health_reason'],
                          state: data['device_state'],
                          online: connectionStatus != 'offline',
                          rssi: data['rssi'],
                          compressorOn: data['compressor_relay_on'],
                          blockReason: data['compressor_block_reason'],
                        ),

                        const SizedBox(height: 8),

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
                            _selectedCoolingLevel != _levelBeforeEdit) ...[
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: () async {
                                final levelToSave = _selectedCoolingLevel;

                                if (levelToSave == null) return;

                                try {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Guardando ajuste...'),
                                      duration: Duration(seconds: 1),
                                    ),
                                  );

                                  final response = await http.post(
                                    Uri.parse(
                                      'https://smartcold-api-649501100610.us-central1.run.app/api/devices/${widget.deviceId}/cooling-level',
                                    ),
                                    headers: {
                                      'Content-Type': 'application/json',
                                    },
                                    body: jsonEncode({
                                      'cooling_level': levelToSave,
                                    }),
                                  );

                                  final body = jsonDecode(response.body);

                                  if (response.statusCode != 200 ||
                                      body['success'] != true) {
                                    throw Exception(
                                      body['message'] ??
                                          'No se pudo guardar el ajuste',
                                    );
                                  }

                                  if (!context.mounted) return;

                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Nivel $levelToSave guardado',
                                      ),
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                  setState(() {
                                    _configCoolingLevel =
                                        _intFromDynamic(
                                          body['cooling_level'],
                                        ) ??
                                        levelToSave;

                                    _configSetpoint =
                                        _doubleFromDynamic(body['setpoint']) ??
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

                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('Error guardando: $e'),
                                      duration: const Duration(seconds: 4),
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
                              physics: const NeverScrollableScrollPhysics(),
                              crossAxisCount: 3,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                              childAspectRatio: constraints.maxWidth < 430
                                  ? 0.95
                                  : 1.25,
                              children: [
                                _KpiCard(
                                  title: 'Cámara',
                                  value: chamberTemp,
                                  suffix: '°C',
                                  icon: Icons.thermostat_rounded,
                                  badgeText: _sensorAlarmText(data, 'chamber'),
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
                                  shouldBeOn: data['compressor_should_be_on'],
                                  protectionSeconds:
                                      data['compressor_wait_seconds_remaining'],
                                  connectionStatus: connectionStatus,
                                  secondsSinceLastSeen: secondsSinceLastSeen,
                                ),
                              ],
                            );
                          },
                        ),

                        const SizedBox(height: 12),

                        LayoutBuilder(
                          builder: (context, constraints) {
                            final defrostCard = _DefrostCard(
                              active: data['defrost_active'],
                              evaporatorTemp: evaporatorTemp,
                              chamberTemp: chamberTemp,
                              endTemperature: data['defrost_end_temperature'],
                              remainingSeconds:
                                  data['defrost_remaining_seconds'],
                              nextSeconds: data['defrost_next_seconds'],
                              durationMinutes: data['defrost_duration_minutes'],
                              intervalMinutes: data['defrost_interval_minutes'],
                              connectionStatus: connectionStatus,
                              secondsSinceLastSeen: secondsSinceLastSeen,
                            );

                            final dripCard = _DripCard(
                              active: data['drip_active'],
                              configuredSeconds: data['drip_time_seconds'],
                              remainingSeconds: data['drip_remaining_seconds'],
                              connectionStatus: connectionStatus,
                              secondsSinceLastSeen: secondsSinceLastSeen,
                            );

                            return IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(child: defrostCard),
                                  const SizedBox(width: 8),
                                  Expanded(child: dripCard),
                                ],
                              ),
                            );
                          },
                        ),
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
          onPressed: () {
            Navigator.of(context).pop();
          },
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
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, color: color, size: 10),
                const SizedBox(width: 5),
                Text(
                  label,
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
  });

  final dynamic deviceName;
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

    final glowLinePaint = Paint()
      ..color = const Color(0xFF00A8FF).withValues(alpha: 0.16)
      ..strokeWidth = 1.2;

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
    final inAlarm = badgeText != 'NORMAL';
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
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Nuevo cliente pendiente')),
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
  bool _wifiConfigured = false;
  String? _configuredWifiName;
  bool _connectionVerified = false;
  bool _sensorsDetected = false;
  bool _sensorRolesAssigned = false;
  //bool get _canConfigureWifi => _selectedDevice != null;

  //bool get _canDetectSensors => _wifiConfigured && _connectionVerified;

  bool get _canAssignRoles => _sensorsDetected && _detectedSensors.isNotEmpty;

  bool get _canConfigureParameters => _canAssignRoles && _sensorRolesAssigned;

  //bool get _canRunTests => false; // luego la conectaremos al paso 5

  List<Map<String, dynamic>> _detectedSensors = [];
  Map<String, Map<String, dynamic>> _assignedSensorsByAddress = {};

  Map<String, String>? _selectedDevice;

  @override
  Widget build(BuildContext context) {
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
            'Sigue los pasos para dejar un dispositivo SmartCold funcionando y visible para el cliente.',
            style: TextStyle(
              color: Color(0xFF9DB0C1),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 18),
          Card(
            color: const Color(0xFF061A2E),
            child: ListTile(
              leading: const Icon(
                Icons.memory_rounded,
                color: Color(0xFF00A8FF),
              ),
              title: const Text(
                '1. Conectar con dispositivo',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
              ),
              subtitle: Text(
                _selectedDevice == null
                    ? 'Detectar el ESP32 SmartCold que será instalado.'
                    : 'Dispositivo seleccionado: ${_selectedDevice!['device_id']} · Firmware ${_selectedDevice!['firmware_version']}',
                style: const TextStyle(color: Color(0xFF9DB0C1)),
              ),
              trailing: Icon(
                _selectedDevice == null
                    ? Icons.chevron_right_rounded
                    : Icons.check_circle_rounded,
                color: _selectedDevice == null
                    ? Colors.white
                    : const Color(0xFF20D76D),
              ),
              onTap: () async {
                var blockingVisible = false;

                void showMessage(String message) {
                  if (blockingVisible) {
                    _closeBlockingMessage();
                    blockingVisible = false;
                  }

                  _showBlockingMessage(message);
                  blockingVisible = true;
                }

                void closeMessage() {
                  if (blockingVisible) {
                    _closeBlockingMessage();
                    blockingVisible = false;
                  }
                }

                try {
                  showMessage('Buscando dispositivos SmartCold cercanos...');

                  final devices = await _scanSmartColdDevices();

                  if (!context.mounted) return;
                  closeMessage();

                  if (devices.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'No se encontraron dispositivos SmartCold cercanos.',
                        ),
                      ),
                    );
                    return;
                  }

                  final selected =
                      await showModalBottomSheet<Map<String, String>>(
                        context: context,
                        backgroundColor: const Color(0xFF020B14),
                        builder: (context) {
                          return SafeArea(
                            child: ListView(
                              padding: const EdgeInsets.all(16),
                              children: [
                                const Text(
                                  'Dispositivos SmartCold detectados',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 20,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                ...devices.map((device) {
                                  return Card(
                                    color: const Color(0xFF061A2E),
                                    child: ListTile(
                                      leading: const Icon(
                                        Icons.memory_rounded,
                                        color: Color(0xFF00A8FF),
                                      ),
                                      title: Text(
                                        device['device_id'] ??
                                            'SmartCold desconocido',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                      subtitle: Text(
                                        'Señal: ${device['rssi'] ?? '—'} dBm',
                                        style: const TextStyle(
                                          color: Color(0xFF9DB0C1),
                                        ),
                                      ),
                                      onTap: () {
                                        Navigator.pop(context, device);
                                      },
                                    ),
                                  );
                                }),
                              ],
                            ),
                          );
                        },
                      );

                  if (selected == null) return;

                  final selectedDeviceId = selected['device_id'];

                  if (selectedDeviceId == null || selectedDeviceId.isEmpty) {
                    if (!context.mounted) return;

                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'El dispositivo seleccionado no tiene nombre válido.',
                        ),
                      ),
                    );
                    return;
                  }

                  final currentDeviceId = _selectedDevice?['device_id'];
                  final isSameDevice = currentDeviceId == selectedDeviceId;

                  if (_selectedDevice != null && !isSameDevice) {
                    final confirmChange = await showDialog<bool>(
                      context: context,
                      builder: (context) {
                        return AlertDialog(
                          title: const Text('Cambiar dispositivo'),
                          content: const Text(
                            'Seleccionaste un dispositivo diferente. Si continúas, se reiniciarán los pasos de WiFi, sensores y roles de esta instalación.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Cancelar'),
                            ),
                            ElevatedButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Cambiar dispositivo'),
                            ),
                          ],
                        );
                      },
                    );

                    if (confirmChange != true) return;
                  }

                  if (!context.mounted) return;
                  showMessage('Conectando con dispositivo SmartCold...');

                  final connectedToEsp = await _connectToEspAccessPoint(
                    selectedDeviceId,
                  );

                  if (!context.mounted) return;

                  if (!connectedToEsp) {
                    closeMessage();

                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'No se pudo conectar al dispositivo SmartCold.',
                        ),
                      ),
                    );
                    return;
                  }

                  showMessage('Leyendo información del dispositivo...');

                  final deviceInfo = await _fetchEspDeviceInfo(selected);
                  Map<String, dynamic>? sensorsResult;
                  List<Map<String, dynamic>> sensors = [];
                  final assigned = <String, Map<String, dynamic>>{};

                  try {
                    sensorsResult = await _fetchInstallSensorsFromEsp();

                    final sensorsRaw = sensorsResult['sensors'];

                    sensors = sensorsRaw is List
                        ? sensorsRaw
                              .whereType<Map>()
                              .map((item) => Map<String, dynamic>.from(item))
                              .toList()
                        : <Map<String, dynamic>>[];

                    for (final sensor in sensors) {
                      final address = sensor['address']?.toString() ?? '';
                      final configured = sensor['configured'] == true;

                      if (address.isNotEmpty && configured) {
                        assigned[address] = Map<String, dynamic>.from(sensor);
                      }
                    }
                  } catch (_) {
                    sensorsResult = null;
                  }
                  if (!context.mounted) return;
                  closeMessage();

                  final espConfigured = deviceInfo['configured'] == 'true';
                  final espWifiConfigured =
                      deviceInfo['wifi_configured'] == 'true';
                  final espConnectionVerified =
                      deviceInfo['connection_verified'] == 'true';
                  final espSensorsDetected =
                      deviceInfo['sensors_detected'] == 'true';
                  final espSensorsAssigned =
                      deviceInfo['sensors_assigned'] == 'true';
                  final espWifiSsid = deviceInfo['configured_wifi_ssid'] ?? '';

                  setState(() {
                    _selectedDevice = deviceInfo;

                    if (espConfigured) {
                      _wifiConfigured = true;
                      _connectionVerified = true;

                      _detectedSensors = sensors;
                      _assignedSensorsByAddress = assigned;

                      _sensorsDetected =
                          sensorsResult?['sensors_detected'] == true ||
                          sensors.isNotEmpty;

                      _sensorRolesAssigned =
                          sensorsResult?['sensors_assigned'] == true ||
                          assigned.isNotEmpty;

                      _configuredWifiName = espWifiSsid.isEmpty
                          ? null
                          : espWifiSsid;
                    } else {
                      _wifiConfigured = espWifiConfigured;
                      _connectionVerified = espConnectionVerified;

                      _detectedSensors = sensors;
                      _assignedSensorsByAddress = assigned;

                      _sensorsDetected =
                          sensorsResult?['sensors_detected'] == true ||
                          sensors.isNotEmpty;

                      _sensorRolesAssigned =
                          sensorsResult?['sensors_assigned'] == true ||
                          assigned.isNotEmpty;

                      _configuredWifiName = espWifiSsid.isEmpty
                          ? null
                          : espWifiSsid;

                      if (!espWifiConfigured) {
                        _connectionVerified = false;
                        _sensorsDetected = false;
                        _sensorRolesAssigned = false;
                        _detectedSensors = [];
                        _assignedSensorsByAddress = {};
                        _configuredWifiName = null;
                      }
                    }
                  });
                  if (espWifiConfigured || espConnectionVerified) {
                    await _releaseEspAccessPointConnection();

                    if (!context.mounted) return;
                  }
                  if (espWifiConfigured) {
                    await WiFiForIoTPlugin.forceWifiUsage(false);
                    await WiFiForIoTPlugin.disconnect();

                    if (!context.mounted) return;
                  }
                } catch (error) {
                  if (!context.mounted) return;

                  closeMessage();

                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error conectando con dispositivo: $error'),
                    ),
                  );
                }
              },
            ),
          ),

          if (_selectedDevice != null) ...[
            const SizedBox(height: 14),
            Card(
              color: const Color(0xFF061A2E),
              child: ListTile(
                leading: const Icon(
                  Icons.wifi_rounded,
                  color: Color(0xFF00A8FF),
                ),
                title: const Text(
                  '2. Configurar WiFi',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                subtitle: Text(
                  _wifiConfigured
                      ? 'WiFi seleccionado: ${_configuredWifiName ?? 'red guardada'}'
                      : 'Seleccionar red WiFi del cliente.',
                  style: const TextStyle(color: Color(0xFF9DB0C1)),
                ),
                trailing: Icon(
                  _wifiConfigured
                      ? Icons.check_circle_rounded
                      : Icons.chevron_right_rounded,
                  color: _wifiConfigured ? Color(0xFF20D76D) : Colors.white,
                ),
                onTap: () async {
                  if (_selectedDevice == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Primero conecta un dispositivo SmartCold.',
                        ),
                      ),
                    );
                    return;
                  }

                  if (_wifiConfigured) {
                    final confirmar = await showDialog<bool>(
                      context: context,
                      builder: (context) {
                        return AlertDialog(
                          title: const Text('Reconfigurar WiFi'),
                          content: Text(
                            'El dispositivo ya tiene WiFi configurado'
                            '${_configuredWifiName == null ? '' : ' ($_configuredWifiName)'}. '
                            'Si continúas, se intentará reemplazar la configuración actual.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Cancelar'),
                            ),
                            ElevatedButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Reconfigurar'),
                            ),
                          ],
                        );
                      },
                    );

                    if (confirmar != true) return;
                  }
                  if (_wifiConfigured) {
                    _showBlockingMessage(
                      'Conectando nuevamente con el SmartCold...',
                    );

                    final deviceId = _selectedDevice?['device_id'] ?? '';

                    final connectedToEsp = await _connectToEspAccessPoint(
                      deviceId,
                    );

                    if (!context.mounted) return;
                    _closeBlockingMessage();

                    if (!connectedToEsp) {
                      await _showWifiResultDialog(
                        success: false,
                        title: 'No se pudo conectar al SmartCold',
                        message:
                            'Para reconfigurar el WiFi, el teléfono debe conectarse nuevamente al SmartCold. Intenta otra vez.',
                      );
                      return;
                    }
                  }
                  _showBlockingMessage('Escaneando redes WiFi cercanas...');

                  late final List<Map<String, dynamic>> networks;

                  try {
                    networks = await _scanWifiNetworksFromEsp();
                  } catch (error) {
                    if (!context.mounted) return;
                    _closeBlockingMessage();

                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'No se pudieron escanear las redes WiFi: $error',
                        ),
                      ),
                    );
                    return;
                  }

                  if (!context.mounted) return;
                  _closeBlockingMessage();

                  if (networks.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('No se encontraron redes WiFi cercanas.'),
                      ),
                    );
                    return;
                  }

                  final wifiData =
                      await showModalBottomSheet<Map<String, String>>(
                        context: context,
                        isScrollControlled: true,
                        backgroundColor: const Color(0xFF020B14),
                        builder: (context) {
                          return _WifiConfigSheet(networks: networks);
                        },
                      );

                  if (wifiData == null) return;
                  if (!context.mounted) return;
                  final selectedSsid = wifiData['ssid'] ?? '';
                  final currentSsid = _configuredWifiName ?? '';

                  if (_wifiConfigured && selectedSsid == currentSsid) {
                    await _releaseEspAccessPointConnection();

                    if (!context.mounted) return;

                    await _showWifiResultDialog(
                      success: true,
                      title: 'WiFi sin cambios',
                      message:
                          'El SmartCold ya está configurado con esa red. No se realizó ningún cambio.',
                    );

                    return;
                  }
                  String progressText =
                      'Enviando configuración WiFi al SmartCold...';
                  void Function(void Function())? refreshProgress;

                  void updateProgress(String text) {
                    progressText = text;
                    refreshProgress?.call(() {});
                  }

                  showDialog(
                    context: context,
                    barrierDismissible: false,
                    builder: (dialogContext) {
                      return StatefulBuilder(
                        builder: (context, setDialogState) {
                          refreshProgress = setDialogState;

                          return AlertDialog(
                            backgroundColor: const Color(0xFF061A2E),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const CircularProgressIndicator(),
                                const SizedBox(height: 16),
                                Text(
                                  progressText,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'No cierres la app. Este proceso puede tardar unos segundos.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Color(0xFF9DB0C1),
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  );
                  final hadWifiConfigured = _wifiConfigured;
                  final previousWifiName = _configuredWifiName;
                  final previousConnectionVerified = _connectionVerified;
                  try {
                    updateProgress('Enviando credenciales al dispositivo...');

                    final result = await _sendWifiToEsp(
                      ssid: wifiData['ssid'] ?? '',
                      password: wifiData['password'] ?? '',
                    );

                    final received = result['success'] == true;

                    if (!received) {
                      if (!context.mounted) return;
                      Navigator.of(context, rootNavigator: true).pop();

                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'No se pudo enviar el WiFi al ESP: ${result['error'] ?? 'error desconocido'}',
                          ),
                        ),
                      );
                      return;
                    }

                    updateProgress(
                      'Credenciales enviadas. Esperando respuesta del ESP...',
                    );

                    final verification = await _waitForWifiVerification(
                      onStatus: updateProgress,
                    );

                    if (!context.mounted) return;
                    Navigator.of(context, rootNavigator: true).pop();

                    final verified = verification['backend_verified'] == true;
                    final status = verification['status']?.toString() ?? '';
                    final error = verification['error']?.toString() ?? '';

                    if (!verified || status == 'error') {
                      setState(() {
                        _wifiConfigured = hadWifiConfigured;
                        _configuredWifiName = previousWifiName;
                        _connectionVerified = previousConnectionVerified;
                      });

                      await _releaseEspAccessPointConnection();

                      if (!context.mounted) return;

                      await _showWifiResultDialog(
                        success: false,
                        title: 'No se pudo conectar al WiFi',
                        message: error == 'WIFI_CONNECTION_FAILED'
                            ? 'El SmartCold no logró conectarse a la red seleccionada. Revisa la contraseña e intenta nuevamente.'
                            : 'No se pudo verificar la conexión del SmartCold. Intenta nuevamente.',
                      );
                      return;
                    }

                    setState(() {
                      _configuredWifiName = wifiData['ssid'];
                      _wifiConfigured = true;
                      _connectionVerified = true;
                    });
                    await _releaseEspAccessPointConnection();

                    if (!context.mounted) return;
                    await _showWifiResultDialog(
                      success: true,
                      title: 'Conexión verificada',
                      message:
                          'El SmartCold se conectó correctamente al WiFi. Puedes continuar con la detección de sondas.',
                    );
                  } catch (error) {
                    if (!context.mounted) return;

                    if (Navigator.of(context, rootNavigator: true).canPop()) {
                      Navigator.of(context, rootNavigator: true).pop();
                    }

                    setState(() {
                      _wifiConfigured = hadWifiConfigured;
                      _configuredWifiName = previousWifiName;
                      _connectionVerified = previousConnectionVerified;
                    });
                    await _releaseEspAccessPointConnection();

                    if (!context.mounted) return;
                    await _showWifiResultDialog(
                      success: false,
                      title: 'Error configurando WiFi',
                      message:
                          'No se pudo completar la configuración WiFi. Revisa la conexión con el SmartCold e intenta nuevamente.',
                    );
                  }
                },
              ),
            ),
            if (_wifiConfigured) ...[
              const SizedBox(height: 14),
              if (_connectionVerified) ...[
                const SizedBox(height: 14),
                Card(
                  color: const Color(0xFF061A2E),
                  child: ListTile(
                    leading: const Icon(
                      Icons.thermostat_rounded,
                      color: Color(0xFF00A8FF),
                    ),
                    title: const Text(
                      '3. Detectar sondas',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    subtitle: Text(
                      _sensorsDetected
                          ? 'Se detectaron ${_detectedSensors.length} sonda${_detectedSensors.length == 1 ? '' : 's'} DS18B20.'
                          : 'Buscar sensores conectados al bus OneWire.',
                      style: const TextStyle(color: Color(0xFF9DB0C1)),
                    ),
                    trailing: Icon(
                      _sensorsDetected
                          ? Icons.check_circle_rounded
                          : Icons.chevron_right_rounded,
                      color: _sensorsDetected
                          ? const Color(0xFF20D76D)
                          : Colors.white,
                    ),
                    onTap: () async {
                      try {
                        _showBlockingMessage('Detectando sondas conectadas...');

                        final result = await _fetchInstallSensorsFromEsp();

                        if (!context.mounted) return;
                        _closeBlockingMessage();

                        final sensorsRaw = result['sensors'];

                        final sensors = sensorsRaw is List
                            ? sensorsRaw
                                  .whereType<Map>()
                                  .map(
                                    (item) => Map<String, dynamic>.from(item),
                                  )
                                  .toList()
                            : <Map<String, dynamic>>[];

                        setState(() {
                          _detectedSensors = sensors;
                          _sensorsDetected =
                              result['sensors_detected'] == true ||
                              sensors.isNotEmpty;
                          _sensorRolesAssigned =
                              result['sensors_assigned'] == true;
                        });

                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              sensors.isEmpty
                                  ? 'No se detectaron sondas.'
                                  : 'Se detectaron ${sensors.length} sonda${sensors.length == 1 ? '' : 's'}.',
                            ),
                          ),
                        );
                      } catch (error) {
                        if (!context.mounted) return;
                        _closeBlockingMessage();

                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Error detectando sondas: $error'),
                          ),
                        );
                      }
                    },
                  ),
                ),
                const SizedBox(height: 14),
                Card(
                  color: !_canAssignRoles
                      ? const Color(0xFF101820)
                      : const Color(0xFF061A2E),
                  child: ListTile(
                    leading: Icon(
                      Icons.cable_rounded,
                      color: !_canAssignRoles
                          ? Colors.grey
                          : const Color(0xFF00A8FF),
                    ),
                    title: const Text(
                      '4. Asignar roles de sondas',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    subtitle: Text(
                      _sensorRolesAssigned
                          ? 'Roles asignados: cámara y evaporador.'
                          : 'Indicar qué sonda corresponde a cada parte del equipo.',
                      style: const TextStyle(color: Color(0xFF9DB0C1)),
                    ),
                    trailing: Icon(
                      !_canAssignRoles
                          ? Icons.lock_rounded
                          : _sensorRolesAssigned
                          ? Icons.check_circle_rounded
                          : Icons.chevron_right_rounded,
                      color: !_canAssignRoles
                          ? Colors.grey
                          : _sensorRolesAssigned
                          ? const Color(0xFF20D76D)
                          : Colors.white,
                    ),
                    onTap: !_canAssignRoles
                        ? null
                        : () async {
                            try {
                              _showBlockingMessage(
                                'Actualizando sondas desde el SmartCold...',
                              );

                              final sensorsResult =
                                  await _fetchInstallSensorsFromEsp();

                              if (!context.mounted) return;
                              _closeBlockingMessage();

                              final sensorsRaw = sensorsResult['sensors'];

                              final sensors = sensorsRaw is List
                                  ? sensorsRaw
                                        .whereType<Map>()
                                        .map(
                                          (item) =>
                                              Map<String, dynamic>.from(item),
                                        )
                                        .toList()
                                  : <Map<String, dynamic>>[];

                              final assigned = <String, Map<String, dynamic>>{};

                              for (final sensor in sensors) {
                                final address =
                                    sensor['address']?.toString() ?? '';
                                final configured = sensor['configured'] == true;

                                if (address.isNotEmpty && configured) {
                                  assigned[address] = Map<String, dynamic>.from(
                                    sensor,
                                  );
                                }
                              }

                              setState(() {
                                _detectedSensors = sensors;
                                _assignedSensorsByAddress = assigned;
                                _sensorsDetected =
                                    sensorsResult['sensors_detected'] == true ||
                                    sensors.isNotEmpty;
                                _sensorRolesAssigned =
                                    sensorsResult['sensors_assigned'] == true ||
                                    assigned.isNotEmpty;
                              });
                            } catch (error) {
                              if (!context.mounted) return;
                              _closeBlockingMessage();

                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'No se pudieron actualizar las sondas: $error',
                                  ),
                                ),
                              );
                              return;
                            }
                            final result =
                                await showModalBottomSheet<
                                  Map<String, Map<String, dynamic>>
                                >(
                                  context: context,
                                  isScrollControlled: true,
                                  backgroundColor: const Color(0xFF020B14),
                                  builder: (context) {
                                    return _AssignSensorRolesSheet(
                                      sensors: _detectedSensors,
                                      initialSensors: _assignedSensorsByAddress,
                                    );
                                  },
                                );

                            if (result == null) return;

                            try {
                              _showBlockingMessage(
                                'Guardando sensores en el SmartCold...',
                              );

                              final sensorsToSave = result.values.toList();

                              await _saveInstallSensorsToEsp(sensorsToSave);
                              final refreshedResult =
                                  await _fetchInstallSensorsFromEsp();

                              final refreshedRaw = refreshedResult['sensors'];

                              final refreshedSensors = refreshedRaw is List
                                  ? refreshedRaw
                                        .whereType<Map>()
                                        .map(
                                          (item) =>
                                              Map<String, dynamic>.from(item),
                                        )
                                        .toList()
                                  : <Map<String, dynamic>>[];

                              final refreshedAssigned =
                                  <String, Map<String, dynamic>>{};

                              for (final sensor in refreshedSensors) {
                                final address =
                                    sensor['address']?.toString() ?? '';
                                final configured = sensor['configured'] == true;

                                if (address.isNotEmpty && configured) {
                                  refreshedAssigned[address] =
                                      Map<String, dynamic>.from(sensor);
                                }
                              }
                              if (!context.mounted) return;
                              _closeBlockingMessage();

                              setState(() {
                                _detectedSensors = refreshedSensors;
                                _assignedSensorsByAddress = refreshedAssigned;
                                _sensorsDetected =
                                    refreshedResult['sensors_detected'] ==
                                        true ||
                                    refreshedSensors.isNotEmpty;
                                _sensorRolesAssigned =
                                    refreshedResult['sensors_assigned'] ==
                                        true ||
                                    refreshedAssigned.isNotEmpty;
                              });
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Sensores guardados correctamente.',
                                  ),
                                ),
                              );
                            } catch (error) {
                              if (!context.mounted) return;
                              _closeBlockingMessage();

                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Error guardando sensores: $error',
                                  ),
                                ),
                              );
                            }
                          },
                  ),
                ),
                const SizedBox(height: 14),
                Card(
                  color: !_canConfigureParameters
                      ? const Color(0xFF101820)
                      : const Color(0xFF061A2E),
                  child: ListTile(
                    leading: Icon(
                      Icons.tune_rounded,
                      color: !_canConfigureParameters
                          ? Colors.grey
                          : const Color(0xFF00A8FF),
                    ),
                    title: const Text(
                      '5. Configuración inicial',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    subtitle: const Text(
                      'Configurar parámetros de operación.',
                      style: TextStyle(color: Color(0xFF9DB0C1)),
                    ),
                    trailing: Icon(
                      !_canConfigureParameters
                          ? Icons.lock_rounded
                          : Icons.chevron_right_rounded,
                      color: !_canConfigureParameters
                          ? Colors.grey
                          : Colors.white,
                    ),
                    onTap: !_canConfigureParameters ? null : () async {},
                  ),
                ),
              ],
            ],
          ],
        ],
      ),
    );
  }

  Future<void> _showWifiResultDialog({
    required bool success,
    required String title,
    required String message,
  }) async {
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF061A2E),
          title: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
            ),
          ),
          content: Text(
            message,
            style: const TextStyle(
              color: Color(0xFF9DB0C1),
              fontWeight: FontWeight.w600,
            ),
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: Text(success ? 'Continuar' : 'Entendido'),
            ),
          ],
        );
      },
    );
  }

  void _showBlockingMessage(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF061A2E),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _closeBlockingMessage() {
    if (Navigator.of(context, rootNavigator: true).canPop()) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }

  Future<Map<String, dynamic>> _getWifiStatusFromEsp() async {
    final response = await http
        .get(Uri.parse('http://192.168.4.1/api/wifi/status'))
        .timeout(const Duration(seconds: 5));

    if (response.statusCode != 200) {
      throw Exception('ESP respondió con código ${response.statusCode}');
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _waitForWifiVerification({
    required void Function(String message) onStatus,
  }) async {
    Map<String, dynamic> lastStatus = {'status': 'waiting', 'error': ''};

    for (int i = 0; i < 35; i++) {
      try {
        final status = await _getWifiStatusFromEsp();

        lastStatus = status;

        final wifiStatus = status['status']?.toString() ?? '';
        final backendVerified = status['backend_verified'] == true;
        final error = status['error']?.toString() ?? '';

        if (wifiStatus == 'received') {
          onStatus('Credenciales recibidas por el SmartCold...');
        } else if (wifiStatus == 'connecting') {
          onStatus('Conectando el ESP al WiFi del cliente...');
        } else if (wifiStatus == 'connected') {
          onStatus('ESP conectado al WiFi. Verificando backend...');
        } else if (wifiStatus == 'backend_verified' && backendVerified) {
          onStatus('WiFi y backend verificados correctamente.');
          return status;
        } else if (wifiStatus == 'error' || error == 'WIFI_CONNECTION_FAILED') {
          onStatus('No se pudo conectar al WiFi. Revisa la contraseña.');
          return status;
        } else {
          onStatus('Verificando estado del ESP...');
        }
      } catch (_) {
        final lastError = lastStatus['error']?.toString() ?? '';
        final lastWifiStatus = lastStatus['status']?.toString() ?? '';

        if (lastWifiStatus == 'error' ||
            lastError == 'WIFI_CONNECTION_FAILED') {
          onStatus('No se pudo conectar al WiFi. Revisa la contraseña.');
          return lastStatus;
        }

        onStatus('Esperando respuesta del ESP...');
      }

      await Future.delayed(const Duration(seconds: 1));
    }

    onStatus('No se pudo verificar la conexión.');
    return {
      'status': 'error',
      'error': 'NO_SE_PUDO_VERIFICAR_WIFI',
      'last_status': lastStatus,
    };
  }

  Future<List<Map<String, dynamic>>> _scanWifiNetworksFromEsp() async {
    final response = await http
        .get(Uri.parse('http://192.168.4.1/api/wifi/scan'))
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw Exception('ESP respondió con código ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final networksRaw = data['networks'];

    if (networksRaw is! List) {
      return [];
    }

    return networksRaw
        .whereType<Map>()
        .map(
          (item) => item.map((key, value) => MapEntry(key.toString(), value)),
        )
        .toList();
  }

  Future<Map<String, dynamic>> _sendWifiToEsp({
    required String ssid,
    required String password,
  }) async {
    final response = await http
        .post(
          Uri.parse('http://192.168.4.1/api/wifi/configure'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'ssid': ssid, 'password': password}),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw Exception('ESP respondió con código ${response.statusCode}');
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _fetchInstallSensorsFromEsp() async {
    final urls = [
      'http://192.168.18.67/api/install/sensors',
      'http://192.168.4.1/api/install/sensors',
    ];

    Object? lastError;

    for (final url in urls) {
      try {
        final response = await http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 4));

        if (response.statusCode == 200) {
          return jsonDecode(response.body) as Map<String, dynamic>;
        }

        lastError = 'ESP respondió con código ${response.statusCode} en $url';
      } catch (error) {
        lastError = error;
      }
    }

    throw Exception('No se pudo consultar sensores del ESP: $lastError');
  }

  Future<Map<String, dynamic>> _saveInstallSensorsToEsp(
    List<Map<String, dynamic>> sensors,
  ) async {
    final urls = [
      'http://192.168.18.67/api/install/sensors',
      'http://192.168.4.1/api/install/sensors',
    ];

    Object? lastError;

    final body = jsonEncode({'sensors': sensors});

    for (final url in urls) {
      try {
        final response = await http
            .post(
              Uri.parse(url),
              headers: {'Content-Type': 'application/json'},
              body: body,
            )
            .timeout(const Duration(seconds: 5));

        if (response.statusCode == 200) {
          return jsonDecode(response.body) as Map<String, dynamic>;
        }

        lastError = 'ESP respondió con código ${response.statusCode} en $url';
      } catch (error) {
        lastError = error;
      }
    }

    throw Exception('No se pudo guardar sensores en el ESP: $lastError');
  }

  Future<bool> _connectToEspAccessPoint(String ssid) async {
    final connected = await WiFiForIoTPlugin.connect(
      ssid,
      security: NetworkSecurity.NONE,
      joinOnce: true,
      withInternet: false,
    );

    if (!connected) return false;

    await WiFiForIoTPlugin.forceWifiUsage(true);

    await Future.delayed(const Duration(seconds: 2));

    return true;
  }

  Future<Map<String, String>> _fetchEspDeviceInfo(
    Map<String, String> scannedDevice,
  ) async {
    final response = await http
        .get(Uri.parse('http://192.168.4.1/api/device-info'))
        .timeout(const Duration(seconds: 5));

    if (response.statusCode != 200) {
      throw Exception('ESP respondió con código ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    return {
      'device_id':
          data['device_id']?.toString() ?? scannedDevice['device_id'] ?? '',
      'hardware_uid':
          data['hardware_uid']?.toString() ??
          scannedDevice['hardware_uid'] ??
          '',
      'firmware_version': data['firmware_version']?.toString() ?? 'desconocido',
      'configured': data['configured']?.toString() ?? 'false',
      'provisioning_status':
          data['provisioning_status']?.toString() ?? 'pending_installation',
      'rssi': scannedDevice['rssi'] ?? '',
      'installation_phase':
          data['installation_phase']?.toString() ?? 'wifi_setup',
      'wifi_configured': data['wifi_configured']?.toString() ?? 'false',
      'connection_verified': data['connection_verified']?.toString() ?? 'false',
      'configured_wifi_ssid': data['configured_wifi_ssid']?.toString() ?? '',
      'sensors_detected': data['sensors_detected']?.toString() ?? 'false',
      'sensors_assigned': data['sensors_assigned']?.toString() ?? 'false',
      'sta_ip': data['sta_ip']?.toString() ?? '',
    };
  }

  Future<List<Map<String, String>>> _scanSmartColdDevices() async {
    final canStartScan = await WiFiScan.instance.canStartScan();

    if (canStartScan != CanStartScan.yes) {
      throw Exception('No se puede iniciar el escaneo WiFi: $canStartScan');
    }

    await WiFiScan.instance.startScan();

    final canGetResults = await WiFiScan.instance.canGetScannedResults();

    if (canGetResults != CanGetScannedResults.yes) {
      throw Exception('No se pueden obtener redes WiFi: $canGetResults');
    }

    final networks = await WiFiScan.instance.getScannedResults();

    return networks
        .where((network) => network.ssid.startsWith('SmartCold-'))
        .map((network) {
          final ssid = network.ssid;

          return {
            'device_id': ssid,
            'hardware_uid': ssid.replaceFirst('SmartCold-', ''),
            'firmware_version': 'pendiente',
            'rssi': network.level.toString(),
          };
        })
        .toList();
  }

  Future<void> _releaseEspAccessPointConnection() async {
    try {
      await WiFiForIoTPlugin.forceWifiUsage(false);
      await WiFiForIoTPlugin.disconnect();
      await Future.delayed(const Duration(seconds: 2));
    } catch (_) {
      // No bloqueamos la instalación si Android no permite soltar la red.
    }
  }
}

class _ActiveInstallationsList extends StatelessWidget {
  const _ActiveInstallationsList();

  @override
  Widget build(BuildContext context) {
    final query = FirebaseFirestore.instance
        .collection('installations')
        .where('status', isEqualTo: 'in_progress');

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: query.snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Text(
            'Error cargando instalaciones en progreso',
            style: TextStyle(color: Colors.redAccent),
          );
        }

        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final installations = snapshot.data!.docs;

        if (installations.isEmpty) {
          return const Text(
            'No hay instalaciones en progreso.',
            style: TextStyle(color: Color(0xFF9DB0C1)),
          );
        }

        return Column(
          children: installations.map((doc) {
            final data = doc.data();

            final equipmentName =
                data['equipment_name_at_installation']?.toString() ??
                'Equipo sin nombre';

            final phase = data['phase']?.toString() ?? 'fase desconocida';
            final deviceId = data['device_id']?.toString() ?? 'sin device_id';

            return Card(
              color: const Color(0xFF061A2E),
              margin: const EdgeInsets.only(bottom: 12),
              child: ListTile(
                leading: const Icon(
                  Icons.build_circle_rounded,
                  color: Color(0xFF00A8FF),
                ),
                title: Text(
                  equipmentName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                subtitle: Text(
                  '$deviceId · $phase',
                  style: const TextStyle(color: Color(0xFF9DB0C1)),
                ),
                trailing: const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                ),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          InstallationWizardPage(installationId: doc.id),
                    ),
                  );
                },
              ),
            );
          }).toList(),
        );
      },
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
  });

  final List<Map<String, dynamic>> sensors;
  final Map<String, Map<String, dynamic>> initialSensors;

  @override
  State<_AssignSensorRolesSheet> createState() =>
      _AssignSensorRolesSheetState();
}

class _AssignSensorRolesSheetState extends State<_AssignSensorRolesSheet> {
  late Map<String, Map<String, dynamic>> _sensorsByAddress;
  String? _error;
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

  @override
  void initState() {
    super.initState();
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

    Navigator.pop(context, {
      for (final sensor in selected)
        sensor['address'].toString(): Map<String, dynamic>.from(sensor),
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
                              } else {
                                item['role'] = value;
                                item['name'] = _defaultNameForRole(value);
                                item['enabled'] = true;
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

                  final currentRolesRaw = data['sensor_roles'];
                  final currentRoles = currentRolesRaw is Map
                      ? currentRolesRaw.map(
                          (key, value) =>
                              MapEntry(key.toString(), value.toString()),
                        )
                      : <String, String>{};

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
