package com.dpejoh.specter;

import java.io.ByteArrayOutputStream;
import org.json.JSONArray;
import org.json.JSONObject;

/** Selects a release ZIP and its digest together; never installs an unverified asset. */
public class ReleaseAsset {
    public static void main(String[] args) {
        try {
            if (args.length != 1) throw new IllegalArgumentException("Expected repository owner/name");
            ByteArrayOutputStream input = new ByteArrayOutputStream();
            byte[] buffer = new byte[8192];
            int length;
            while ((length = System.in.read(buffer)) != -1) input.write(buffer, 0, length);
            String json = input.toString("UTF-8");
            JSONArray assets = new JSONObject(json).getJSONArray("assets");
            String debug = null;
            for (int i = 0; i < assets.length(); i++) {
                JSONObject asset = assets.getJSONObject(i);
                String url = asset.optString("browser_download_url", "");
                String digest = asset.optString("digest", "");
                if (!url.startsWith("https://github.com/" + args[0] + "/releases/download/")
                    || !url.endsWith(".zip") || !digest.matches("sha256:[0-9a-fA-F]{64}")) continue;
                String selection = url + "|" + digest.substring(7).toLowerCase(java.util.Locale.ROOT);
                if (asset.optString("name", "").toLowerCase(java.util.Locale.ROOT).contains("debug")) {
                    if (debug == null) debug = selection;
                } else {
                    System.out.println(selection);
                    return;
                }
            }
            if (debug == null) throw new IllegalArgumentException("No ZIP with a valid SHA-256 digest");
            System.out.println(debug);
        } catch (Exception e) {
            System.err.println("Release asset selection failed: " + e.getMessage());
            System.exit(1);
        }
    }
}
