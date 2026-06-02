package com.goose.android;

final class Hex {
    private static final char[] DIGITS = "0123456789abcdef".toCharArray();

    private Hex() {
    }

    static String encode(byte[] bytes) {
        char[] out = new char[bytes.length * 2];
        for (int index = 0; index < bytes.length; index += 1) {
            int value = bytes[index] & 0xff;
            out[index * 2] = DIGITS[value >>> 4];
            out[index * 2 + 1] = DIGITS[value & 0x0f];
        }
        return new String(out);
    }

    static byte[] decode(String hex) {
        String normalized = hex.replaceAll("\\s+", "");
        if ((normalized.length() % 2) != 0) {
            throw new IllegalArgumentException("hex string length must be even");
        }
        byte[] out = new byte[normalized.length() / 2];
        for (int index = 0; index < normalized.length(); index += 2) {
            out[index / 2] = (byte) Integer.parseInt(normalized.substring(index, index + 2), 16);
        }
        return out;
    }
}
