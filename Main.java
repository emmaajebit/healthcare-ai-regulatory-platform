import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;

/**
 * Minimal demo service for the healthcare-ai platform PoC.
 * Serves JSON on port 8080 so pipeline probes, ArgoCD health checks and
 * the k6 load test have a real endpoint to hit.
 */
public class Main {
    public static void main(String[] args) throws Exception {
        HttpServer server = HttpServer.create(new InetSocketAddress(8080), 0);
        server.createContext("/", exchange -> {
            String path = exchange.getRequestURI().getPath();
            String body = "{\"status\":\"ok\",\"app\":\"java-healthcare-app\","
                    + "\"version\":\"1.0.0\",\"path\":\"" + path + "\"}";
            byte[] bytes = body.getBytes(java.nio.charset.StandardCharsets.UTF_8);
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, bytes.length);
            exchange.getResponseBody().write(bytes);
            exchange.close();
        });
        server.start();
        System.out.println("java-healthcare-app listening on :8080");
    }
}
