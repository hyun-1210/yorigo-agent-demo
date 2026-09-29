import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../widgets/app_header.dart';

class EmptyRecipeScreen extends StatelessWidget {
  const EmptyRecipeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Scaffold(
      backgroundColor: AppColors.getBackground(brightness),
      body: SafeArea(
        child: Column(
          children: [
            AppHeader(
              onLoginPressed: () {
                Navigator.pushNamed(context, '/login');
              },
            ),
            Expanded(
              child: Container(
                color: AppColors.getBackgroundSecondary(brightness),
                child: Center(
                  child: Text(
                    '레시피',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: AppColors.getTextPrimary(brightness),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
