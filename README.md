# Landman Website - Flutter App

A responsive Flutter application implementing the Account Settings design from Figma.

## Features

- Responsive design that adapts to mobile, tablet, and desktop screens
- Account Settings page with Personal Details and Password sections
- Sidebar navigation with collapsible menu on mobile
- Clean, modern UI matching the Figma design

## Screen Sizes

- Desktop: 1440x1024 (original design)
- Tablet: 768px - 1024px
- Mobile: < 768px

## Getting Started

1. Make sure you have Flutter installed (SDK >= 3.0.0)
2. Install dependencies:
   ```bash
   flutter pub get
   ```
3. Run the app:
   ```bash
   flutter run
   ```

## Desktop Build (Downloadable App)

Desktop targets are enabled for macOS, Windows, and Linux.

1. Generate release build:
   ```bash
   flutter build macos --release
   ```
2. App bundle output:
   ```text
   build/macos/Build/Products/Release/landman_website.app
   ```
3. Create a downloadable zip:
   ```bash
   cd build/macos/Build/Products/Release
   zip -r landman_website-macos.zip landman_website.app
   ```

For Windows/Linux, run `flutter build windows --release` or
`flutter build linux --release` on those respective operating systems.

## Project Structure

```
lib/
  ├── main.dart
  ├── screens/
  │   └── account_settings_screen.dart
  └── widgets/
      ├── sidebar_navigation.dart
      ├── nav_link.dart
      ├── account_settings_content.dart
      ├── personal_details_card.dart
      └── password_card.dart
```

## Responsive Behavior

- **Desktop (>1024px)**: Fixed sidebar (252px) with main content area
- **Tablet (768-1024px)**: Sidebar and content side by side with adjusted padding
- **Mobile (<768px)**: Collapsible sidebar overlay with hamburger menu
