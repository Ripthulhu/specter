package com.dpejoh.specter;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.URL;
import javax.net.ssl.HttpsURLConnection;

/** Uses the platform trust store and hostname verifier, including on curl-less devices. */
public class HttpsDownload {
    public static void main(String[] args) {
        if (args.length != 3) {
            System.err.println("Usage: HttpsDownload URL OUTPUT USER_AGENT");
            System.exit(1);
        }
        File output = new File(args[1]);
        try {
            URL url = new URL(args[0]);
            for (int redirects = 0; redirects <= 5; redirects++) {
                if (!"https".equalsIgnoreCase(url.getProtocol())) {
                    throw new IOException("Only HTTPS downloads are allowed");
                }
                HttpsURLConnection connection = (HttpsURLConnection) url.openConnection();
                connection.setInstanceFollowRedirects(false);
                connection.setConnectTimeout(10000);
                connection.setReadTimeout(10000);
                connection.setRequestProperty("User-Agent", args[2]);
                try {
                    int status = connection.getResponseCode();
                    if (status == 301 || status == 302 || status == 303 || status == 307 || status == 308) {
                        String location = connection.getHeaderField("Location");
                        if (location == null) throw new IOException("Redirect missing Location");
                        url = new URL(url, location);
                        continue;
                    }
                    if (status < 200 || status >= 300) throw new IOException("HTTP status " + status);
                    try (InputStream input = connection.getInputStream();
                         FileOutputStream stream = new FileOutputStream(output)) {
                        byte[] buffer = new byte[8192];
                        int length;
                        while ((length = input.read(buffer)) != -1) stream.write(buffer, 0, length);
                    }
                    return;
                } finally {
                    connection.disconnect();
                }
            }
            throw new IOException("Too many redirects");
        } catch (Exception e) {
            output.delete();
            System.err.println("HTTPS download failed: " + e.getMessage());
            System.exit(1);
        }
    }
}
