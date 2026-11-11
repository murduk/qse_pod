package com.example;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import javax.crypto.Cipher;

/** Test fixture: deliberately uses weak cryptography so QSE has findings. */
public class WeakHash {
    public static byte[] md5(String input) throws NoSuchAlgorithmException {
        return MessageDigest.getInstance("MD5").digest(input.getBytes(StandardCharsets.UTF_8));
    }

    public static Cipher des() throws Exception {
        return Cipher.getInstance("DES/ECB/PKCS5Padding");
    }

    public static void main(String[] args) throws Exception {
        System.out.println(md5("hello").length);
    }
}
