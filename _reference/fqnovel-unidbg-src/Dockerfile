# fqnovel-unidbg 签名服务镜像
# 构建: docker build -t fq-unidbg:latest .
# 运行: 见 docs/NAS部署脚本.md 的 fq-unidbg 服务段

# ── 构建阶段（Maven + 阿里云镜像源）────────────────────────────────
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /src
COPY pom.xml ./
# 先拷 pom 单独下载依赖，利用层缓存
RUN mkdir -p /root/.m2 && printf '<settings><mirrors><mirror><id>aliyun</id><mirrorOf>central</mirrorOf><url>https://maven.aliyun.com/repository/public</url></mirror></mirrors></settings>' > /root/.m2/settings.xml && mvn -q -B dependency:go-offline || true
COPY src ./src
COPY application.yml ./
RUN mvn -q -B -DskipTests package

# ── 运行阶段 ───────────────────────────────────────────────────────
FROM eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /src/target/unidbg-boot-server-0.0.1-SNAPSHOT.jar app.jar
EXPOSE 9999
# 设备配置持久化: 挂载 ./config/application.yml（Spring Boot 默认读取 ./config/ 覆盖包内配置）
ENTRYPOINT ["java", "-Dfile.encoding=UTF-8", "-jar", "app.jar"]
