package com.anjia.unidbgserver.web;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.zip.GZIPInputStream;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpEntity;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestTemplate;

import com.anjia.unidbgserver.dto.FqVariable;
import com.anjia.unidbgserver.service.FQEncryptServiceWorker;
import com.anjia.unidbgserver.utils.FQApiUtils;

import lombok.extern.slf4j.Slf4j;

/**
 * 通用签名代发端点：用服务自身配置的设备参数拼完整 App URL，
 * 经 IdleFQ 签名后代发 GET，返回上游原始响应文本。
 * 供外部 server 调用任意 bookapi 端点（如 bookmall/tab 书城 feed）。
 *
 * 注意：query 必须是"已按 App 格式编码"的业务参数串（形如 a=%5B..%5D&b=1），
 * 本端点不再做二次编码；公共设备参数（aid/device_id/iid/cdid/version_* 等）
 * 由服务配置提供，query 中同名键可覆盖。
 */
@Slf4j
@RestController
@RequestMapping(path = "/api/fqapp", produces = MediaType.APPLICATION_JSON_VALUE)
public class FQAppProxyController {

    @Autowired
    private FQEncryptServiceWorker fqEncryptServiceWorker;

    @Autowired
    private FQApiUtils fqApiUtils;

    private final RestTemplate restTemplate = new RestTemplate();

    private com.anjia.unidbgserver.config.FQApiProperties fqApiProperties;

    private FqVariable defaultFqVariable;

    @org.springframework.beans.factory.annotation.Autowired
    public void setFqApiProperties(com.anjia.unidbgserver.config.FQApiProperties p) {
        this.fqApiProperties = p;
    }

    private FqVariable getDefaultFqVariable() {
        if (defaultFqVariable == null) {
            defaultFqVariable = new FqVariable(fqApiProperties);
        }
        return defaultFqVariable;
    }

    public static class FetchRequest {
        public String path;   // 如 /reading/bookapi/bookmall/tab/v
        public String query;  // 已编码的业务参数串（可选）
        public String host;   // 可选 host 覆盖（如 api5-normal-sinfonlinec.fqnovel.com）
    }

    @PostMapping(value = "/fetch", consumes = MediaType.APPLICATION_JSON_VALUE)
    public CompletableFuture<ResponseEntity<String>> fetch(@RequestBody FetchRequest req) {
        return CompletableFuture.supplyAsync(() -> {
            try {
                FqVariable var = getDefaultFqVariable();
                Map<String, String> params = new HashMap<>(fqApiUtils.buildCommonApiParams(var));
                if (req.query != null && !req.query.trim().isEmpty()) {
                    for (String kv : req.query.split("&")) {
                        if (kv.isEmpty()) continue;
                        int eq = kv.indexOf('=');
                        if (eq >= 0) {
                            params.put(kv.substring(0, eq), kv.substring(eq + 1));
                        } else {
                            params.put(kv, "");
                        }
                    }
                }
                String base = fqApiUtils.getBaseUrl();
                if (req.host != null && !req.host.trim().isEmpty()) {
                    base = base.replaceFirst("https://[^/]+", req.host);
                }
                String fullUrl = fqApiUtils.buildUrlWithParams(base + req.path, params);

                Map<String, String> headers = fqApiUtils.buildCommonHeaders();
                headers.put("Authorization", "Bearer");

                Map<String, String> signed = fqEncryptServiceWorker
                        .generateSignatureHeaders(fullUrl, headers).get();

                HttpHeaders httpHeaders = new HttpHeaders();
                signed.forEach(httpHeaders::set);
                headers.forEach(httpHeaders::set);

                ResponseEntity<byte[]> response = restTemplate.exchange(
                        URI.create(fullUrl), HttpMethod.GET, new HttpEntity<>(httpHeaders), byte[].class);

                String body = decompressGzipResponse(response.getBody());
                log.debug("[fqapp/fetch] {} -> {} bytes", req.path, body == null ? 0 : body.length());
                return ResponseEntity.ok(body == null ? "" : body);
            } catch (Exception e) {
                log.error("[fqapp/fetch] 代发失败 path={}", req.path, e);
                return ResponseEntity.status(502)
                        .body("{\"error\":\"fqapp fetch failed: " + String.valueOf(e.getMessage())
                                .replace("\"", "'") + "\"}");
            }
        });
    }

    private String decompressGzipResponse(byte[] gzipData) throws Exception {
        if (gzipData == null || gzipData.length < 2 || (gzipData[0] & 0xFF) != 0x1F) {
            return new String(gzipData == null ? new byte[0] : gzipData, StandardCharsets.UTF_8);
        }
        try (GZIPInputStream gzipInputStream = new GZIPInputStream(new ByteArrayInputStream(gzipData))) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buffer = new byte[4096];
            int len;
            while ((len = gzipInputStream.read(buffer)) != -1) {
                out.write(buffer, 0, len);
            }
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        }
    }
}
