# Keep rules for the release build (R8).
# Without these, R8 can strip classes that flutter_local_notifications reads
# back (with Gson) when an alarm fires, so scheduled alarms silently never ring
# in the release APK even though they work with `flutter run`.

-keepattributes Signature
-keepattributes *Annotation*

-keep class com.dexterous.** { *; }

-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
