# Inherited from BestToDo, where Best Music used to be a build flavor: keep
# generic signatures and Gson's reflection targets (R8 full mode, the default
# on AGP 8+, strips them otherwise). Best Music has always shipped with these
# rules; they stay so the split changes nothing in release builds.
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes EnclosingMethod
-keepattributes InnerClasses

-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep public class * implements java.lang.reflect.Type

# Gson itself plus the plugin's model classes that get (de)serialized.
-keep class com.google.gson.** { *; }
-keep class com.dexterous.flutterlocalnotifications.** { *; }
-dontwarn com.google.gson.**
