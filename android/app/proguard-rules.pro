# ML Kit 的文字识别插件会在 TextRecognizer 里引用各语种的可选模型类
# （例如韩语 KoreanTextRecognizerOptions），但只有中文/拉丁模型被实际打包。
# 不告诉 R8 忽略这些引用，release 构建会在 minifyReleaseWithR8 阶段失败。
-dontwarn com.google.mlkit.**
-keep class com.google.mlkit.** { *; }
-dontwarn com.google.android.gms.**
-keep class com.google.android.gms.** { *; }
