package com.molido.vpn

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

object SecureStore {
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val KEY_ALIAS = "molido_credential_key"
    // Alias used by earlier builds. Keystore keys are non-exportable, so instead of
    // copying the key we keep using it while it exists: new installs get the new
    // alias, existing installs keep decrypting their stored credentials.
    private const val LEGACY_KEY_ALIAS = "msnguard_credential_key"
    private const val PREFS_NAME = "secure_settings"
    private const val GCM_IV_LENGTH = 12
    private const val GCM_TAG_LENGTH = 128

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        for (alias in arrayOf(KEY_ALIAS, LEGACY_KEY_ALIAS)) {
            if (keyStore.containsAlias(alias)) {
                val entry = keyStore.getEntry(alias, null) as? KeyStore.SecretKeyEntry
                if (entry != null) return entry.secretKey
            }
        }

        val keyGenerator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            ANDROID_KEYSTORE,
        )
        val spec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build()
        keyGenerator.init(spec)
        return keyGenerator.generateKey()
    }

    fun encrypt(plainText: String): String {
        if (plainText.isEmpty()) return ""
        return try {
            val key = getOrCreateKey()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key)
            val iv = cipher.iv
            val cipherText = cipher.doFinal(plainText.toByteArray(Charsets.UTF_8))
            val combined = ByteArray(iv.size + cipherText.size)
            System.arraycopy(iv, 0, combined, 0, iv.size)
            System.arraycopy(cipherText, 0, combined, iv.size, cipherText.size)
            Base64.encodeToString(combined, Base64.NO_WRAP)
        } catch (_: Exception) {
            plainText
        }
    }

    fun decrypt(encryptedBase64: String): String {
        if (encryptedBase64.isEmpty()) return ""
        return try {
            val combined = Base64.decode(encryptedBase64, Base64.NO_WRAP)
            if (combined.size <= GCM_IV_LENGTH) return encryptedBase64
            val key = getOrCreateKey()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            val spec = GCMParameterSpec(GCM_TAG_LENGTH, combined, 0, GCM_IV_LENGTH)
            cipher.init(Cipher.DECRYPT_MODE, key, spec)
            val plainBytes = cipher.doFinal(combined, GCM_IV_LENGTH, combined.size - GCM_IV_LENGTH)
            String(plainBytes, Charsets.UTF_8)
        } catch (_: Exception) {
            encryptedBase64
        }
    }

    fun putSecret(context: Context, key: String, value: String) {
        val encrypted = if (value.isNotBlank()) encrypt(value) else ""
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(key, encrypted)
            .apply()
        // Clean from plain prefs if it was there
        context.getSharedPreferences("settings", Context.MODE_PRIVATE)
            .edit()
            .remove(key)
            .apply()
    }

    fun getSecret(context: Context, key: String, fallback: String = ""): String {
        val securePrefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val encrypted = securePrefs.getString(key, null)
        if (encrypted != null) {
            return decrypt(encrypted).ifBlank { fallback }
        }
        // Fallback to legacy plain settings for migration
        val plainPrefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
        val legacy = plainPrefs.getString(key, null)
        if (!legacy.isNullOrBlank()) {
            putSecret(context, key, legacy)
            return legacy
        }
        return fallback
    }

    fun removeSecret(context: Context, key: String) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .remove(key)
            .apply()
        context.getSharedPreferences("settings", Context.MODE_PRIVATE)
            .edit()
            .remove(key)
            .apply()
    }
}

/** Native Android IKEv2/IPsec client using the platform VpnManager (Android 11+). */
class Ikev2Activity : android.app.Activity() {
    private lateinit var serverField: android.widget.EditText
    private lateinit var identityField: android.widget.EditText
    private lateinit var usernameField: android.widget.EditText
    private lateinit var passwordField: android.widget.EditText
    private val manager: android.net.VpnManager
        get() = getSystemService(android.net.VpnManager::class.java)

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        if (android.os.Build.VERSION.SDK_INT < 30) {
            android.widget.Toast.makeText(this, "IKEv2 native mode requires Android 11 or newer.", android.widget.Toast.LENGTH_LONG).show()
            finish()
            return
        }
        val prefs = getSharedPreferences("ikev2_profile", Context.MODE_PRIVATE)
        val root = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            setPadding(48, 48, 48, 32)
            setBackgroundColor(android.graphics.Color.rgb(15, 20, 30))
        }
        fun field(hintText: String, value: String = "", password: Boolean = false) =
            android.widget.EditText(this).apply {
                hint = hintText
                setText(value)
                setTextColor(android.graphics.Color.WHITE)
                setHintTextColor(android.graphics.Color.LTGRAY)
                textSize = 16f
                setSingleLine(true)
                inputType = if (password) android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD else android.text.InputType.TYPE_CLASS_TEXT
                setPadding(24, 18, 24, 18)
            }
        root.addView(android.widget.TextView(this).apply {
            text = "IKEv2 / IPsec"
            textSize = 24f
            setTextColor(android.graphics.Color.WHITE)
        })
        root.addView(android.widget.TextView(this).apply {
            text = "Native Android VPN · Android 11+"
            textSize = 13f
            setTextColor(android.graphics.Color.LTGRAY)
        })
        serverField = field("VPN server (hostname)", prefs.getString("server", "") ?: "")
        identityField = field("Remote identity", prefs.getString("identity", "") ?: "")
        usernameField = field("Username", SecureStore.getSecret(this, "ikev2_username"))
        passwordField = field("Password", SecureStore.getSecret(this, "ikev2_password"), true)
        listOf(serverField, identityField, usernameField, passwordField).forEach { input ->
            root.addView(input, android.widget.LinearLayout.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT, android.view.ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = 18 })
        }
        root.addView(android.widget.Button(this).apply {
            text = "Connect with IKEv2"
            setOnClickListener { provisionAndConnect() }
        }, android.widget.LinearLayout.LayoutParams(
            android.view.ViewGroup.LayoutParams.MATCH_PARENT, android.view.ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply { topMargin = 24 })
        root.addView(android.widget.Button(this).apply {
            text = "Disconnect IKEv2"
            setOnClickListener {
                try {
                    manager.stopProvisionedVpnProfile()
                    android.widget.Toast.makeText(this@Ikev2Activity, "IKEv2 disconnect requested", android.widget.Toast.LENGTH_SHORT).show()
                } catch (e: Exception) { showError(e) }
            }
        }, android.widget.LinearLayout.LayoutParams(
            android.view.ViewGroup.LayoutParams.MATCH_PARENT, android.view.ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply { topMargin = 8 })
        setContentView(android.widget.ScrollView(this).apply { addView(root) })
    }

    private fun provisionAndConnect() {
        val server = serverField.text.toString().trim()
        val identity = identityField.text.toString().trim()
        val username = usernameField.text.toString()
        val password = passwordField.text.toString()
        if (server.isBlank() || identity.isBlank() || username.isBlank() || password.isBlank()) {
            android.widget.Toast.makeText(this, "Enter server, remote identity, username and password.", android.widget.Toast.LENGTH_LONG).show()
            return
        }
        if (!server.matches(Regex("(?i)^[a-z0-9.-]+$")) || server.startsWith(".") || server.endsWith(".")) {
            serverField.error = "Enter a valid hostname or IPv4 address"
            return
        }
        try {
            getSharedPreferences("ikev2_profile", Context.MODE_PRIVATE).edit()
                .putString("server", server).putString("identity", identity).apply()
            SecureStore.putSecret(this, "ikev2_username", username)
            SecureStore.putSecret(this, "ikev2_password", password)
            val profile = android.net.Ikev2VpnProfile.Builder(server, identity)
                .setAuthUsernamePassword(username, password, null)
                .setBypassable(false)
                .build()
            startActivityForResult(manager.provisionVpnProfile(profile), REQUEST_PROVISION)
        } catch (e: Exception) { showError(e) }
    }

    @Deprecated("Android platform VPN consent callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_PROVISION) return
        if (resultCode != RESULT_OK) {
            android.widget.Toast.makeText(this, "IKEv2 permission was not granted.", android.widget.Toast.LENGTH_LONG).show()
            return
        }
        try {
            manager.startProvisionedVpnProfile()
            android.widget.Toast.makeText(this, "IKEv2 connection requested. Android is establishing the tunnel.", android.widget.Toast.LENGTH_LONG).show()
        } catch (e: Exception) { showError(e) }
    }

    private fun showError(error: Exception) {
        android.util.Log.e("MolidoIKEv2", "IKEv2 operation failed", error)
        android.widget.Toast.makeText(this, "IKEv2: ${error.localizedMessage ?: error.javaClass.simpleName}", android.widget.Toast.LENGTH_LONG).show()
    }

    companion object { private const val REQUEST_PROVISION = 7421 }
}

