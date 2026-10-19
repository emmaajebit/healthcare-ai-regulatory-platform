# PoC application container for the healthcare-ai platform.
# Single-file Java service (no build system) — compiled in a JDK stage,
# run on a slim JRE. Matches the Helm chart: port 8080, non-root user 1000.
FROM eclipse-temurin:21-jdk-alpine AS build
WORKDIR /src
COPY Main.java .
RUN javac Main.java

FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY --from=build /src/Main.class .
USER 1000
EXPOSE 8080
# -XX:-UsePerfData avoids /tmp writes (chart sets readOnlyRootFilesystem: true)
CMD ["java", "-XX:-UsePerfData", "Main"]
