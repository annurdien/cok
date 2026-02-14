#!/usr/bin/env swift

import Crypto
import Foundation

/// Simple script to generate API keys for Cok tunnel clients
/// Usage: swift Scripts/generate-api-key.swift [subdomain] [secret] [expires-in-hours]

struct APIKey {
    let key: String
    let subdomain: String
    let createdAt: Date
    let expiresAt: Date?
    
    func printDetails() {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        
        print("📋 API Key Generated")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("Subdomain:    \(subdomain)")
        print("API Key:      \(key)")
        print("Created:      \(formatter.string(from: createdAt))")
        if let expiresAt = expiresAt {
            print("Expires:      \(formatter.string(from: expiresAt))")
        } else {
            print("Expires:      Never")
        }
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print()
        print("🚀 Your client can now connect using:")
        print("   cok -p 3000 -s \(subdomain) --api-key \(key)")
        print()
        print("Or set environment variables:")
        print("   export COK_API_KEY=\"\(key)\"")
        print("   export COK_SUBDOMAIN=\"\(subdomain)\"")
        print("   cok -p 3000")
    }
}

func generateAPIKey(subdomain: String, secret: String, expiresInHours: Double? = nil) -> APIKey {
    // Use HMAC-SHA256 for API key generation (same as AuthService)
    let timestamp = Date().timeIntervalSince1970
    let message = "\(subdomain):\(UUID().uuidString):\(timestamp)"
    let signature = HMAC<SHA256>.authenticationCode(
        for: Data(message.utf8),
        using: SymmetricKey(data: Data(secret.utf8))
    )
    let keyString = signature.compactMap { String(format: "%02x", $0) }.joined()
    
    let expiresAt = expiresInHours.map { Date().addingTimeInterval($0 * 3600) }
    
    return APIKey(
        key: keyString,
        subdomain: subdomain,
        createdAt: Date(),
        expiresAt: expiresAt
    )
}

func printUsage() {
    print("🔑 Cok API Key Generator")
    print()
    print("Usage:")
    print("  swift Scripts/generate-api-key.swift <subdomain> <secret> [expires-hours]")
    print()
    print("Arguments:")
    print("  subdomain      - Subdomain for this client (e.g., 'myapp', 'client1')")
    print("  secret         - Your COK_API_KEY_SECRET (same as server)")
    print("  expires-hours  - Optional: hours until expiration (omit for no expiry)")
    print()
    print("Examples:")
    print("  # Generate permanent key for 'myapp' subdomain")
    print("  swift Scripts/generate-api-key.swift myapp your-secret-key")
    print()
    print("  # Generate key that expires in 24 hours")
    print("  swift Scripts/generate-api-key.swift myapp your-secret-key 24")
    print()
    print("  # Use environment variable for secret")
    print("  swift Scripts/generate-api-key.swift myapp \"$COK_API_KEY_SECRET\"")
}

// Parse command line arguments
let args = CommandLine.arguments
guard args.count >= 3 else {
    printUsage()
    exit(1)
}

let subdomain = args[1]
let secret = args[2]
let expiresInHours = args.count > 3 ? Double(args[3]) : nil

// Validate inputs
guard !subdomain.isEmpty else {
    print("❌ Error: Subdomain cannot be empty")
    exit(1)
}

guard secret.count >= 32 else {
    print("❌ Error: Secret must be at least 32 characters for security")
    print("   Your secret is \(secret.count) characters")
    exit(1)
}

if let hours = expiresInHours, hours <= 0 {
    print("❌ Error: Expiration must be positive number of hours")
    exit(1)
}

// Generate and print the API key
let apiKey = generateAPIKey(
    subdomain: subdomain,
    secret: secret,
    expiresInHours: expiresInHours
)

apiKey.printDetails()