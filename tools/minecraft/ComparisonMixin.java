// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
package org.goanna.comparison;

import com.google.gson.JsonObject;
import com.google.gson.JsonArray;
import com.google.gson.JsonParser;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import net.minecraft.client.Minecraft;
import net.minecraft.client.Screenshot;
import net.minecraft.client.renderer.BiomeColors;
import net.minecraft.client.renderer.texture.TextureAtlas;
import net.minecraft.core.BlockPos;
import net.minecraft.world.attribute.EnvironmentAttributes;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** Local capture commands, executed on the client's own thread. */
@Mixin(Minecraft.class)
public abstract class ComparisonMixin {
    @Unique private JsonObject goannaPose;
    @Unique private JsonObject goannaShot;

    @Unique private Path goannaDirectory() {
        return ((Minecraft) (Object) this).gameDirectory.toPath().resolve(".goanna-control");
    }

    @Unique private void goannaReply(JsonObject request, JsonObject result) {
        try {
            result.add("id", request.get("id"));
            Path temporary = goannaDirectory().resolve("response.tmp");
            Files.writeString(temporary, result.toString());
            Files.move(temporary, goannaDirectory().resolve("response.json"),
                StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        } catch (Exception error) {
            System.err.println("Goanna capture reply failed: " + error);
        }
    }

    @Unique private JsonObject goannaStatus(Minecraft client) {
        JsonObject result = new JsonObject();
        result.addProperty("ok", true);
        result.addProperty("connected", client.level != null && client.player != null);
        result.addProperty("version", client.getLaunchedVersion());
        result.addProperty("fps", client.getFps());
        result.addProperty("texture_filtering", client.options.textureFiltering().get().name());
        result.addProperty("mipmap_levels", client.options.mipmapLevels().get());
        result.addProperty("cloud_setting", client.options.cloudStatus().get().name());
        result.addProperty("effective_cloud_setting", client.options.getCloudStatus().name());
        if (client.level != null) {
            var atlas = client.getTextureManager().getTexture(TextureAtlas.LOCATION_BLOCKS);
            var sampler = atlas.getSampler();
            JsonObject sampling = new JsonObject();
            sampling.addProperty("min_filter", sampler.getMinFilter().name());
            sampling.addProperty("mag_filter", sampler.getMagFilter().name());
            sampling.addProperty("max_anisotropy", sampler.getMaxAnisotropy());
            result.add("block_atlas_sampler", sampling);
            result.addProperty("world_time", client.level.getOverworldClockTime() % 24000);
            result.addProperty("sun_angle_degrees", client.level.environmentAttributes()
                .getDimensionValue(EnvironmentAttributes.SUN_ANGLE));
            result.addProperty("cloud_height", client.level.environmentAttributes()
                .getDimensionValue(EnvironmentAttributes.CLOUD_HEIGHT));
            JsonObject tints = new JsonObject();
            for (String name : new String[]{"water", "leaves"}) {
                BlockPos pos = name.equals("water") ? new BlockPos(3, 99, 11) : new BlockPos(12, 100, 11);
                tints.addProperty(name, name.equals("water")
                    ? BiomeColors.getAverageWaterColor(client.level, pos)
                    : BiomeColors.getAverageFoliageColor(client.level, pos));
            }
            result.add("fixture_tints", tints);
        }
        try {
            Class<?> api = Class.forName("net.irisshaders.iris.api.v0.IrisApi");
            Object iris = api.getMethod("getInstance").invoke(null);
            result.addProperty("shader_active", (Boolean) api.getMethod("isShaderPackInUse").invoke(iris));
            if (result.get("shader_active").getAsBoolean()) {
                Class<?> shadows = Class.forName("net.irisshaders.iris.shadows.ShadowRenderer");
                JsonObject state = new JsonObject();
                state.addProperty("resolution", shadows.getField("RESOLUTION").getInt(null));
                for (String name : new String[]{"MODELVIEW", "PROJECTION"}) {
                    Object matrix = shadows.getField(name).get(null);
                    if (matrix == null) continue;
                    float[] values = (float[]) matrix.getClass().getMethod("get", float[].class)
                        .invoke(matrix, (Object) new float[16]);
                    JsonArray entries = new JsonArray();
                    for (float value : values) entries.add(value);
                    state.add(name.toLowerCase(java.util.Locale.ROOT), entries);
                }
                result.add("shadow_state", state);
            }
        } catch (ReflectiveOperationException error) {
            if (!result.has("shader_active")) result.addProperty("shader_active", false);
            result.addProperty("iris_probe_error", error.toString());
        }
        if (client.player != null) {
            result.addProperty("x", client.player.getX());
            result.addProperty("eye_y", client.player.getY() + client.player.getEyeHeight());
            result.addProperty("z", client.player.getZ());
            result.addProperty("yaw", client.player.getYRot());
            result.addProperty("pitch", client.player.getXRot());
            result.addProperty("fov", client.options.fov().get());
        }
        return result;
    }

    @Inject(method = "tick", at = @At("TAIL"))
    private void goannaTick(CallbackInfo info) {
        Minecraft client = (Minecraft) (Object) this;
        Path requestFile = goannaDirectory().resolve("request.json");
        if (Files.exists(requestFile) && goannaShot == null) {
            JsonObject request = new JsonObject();
            try {
                request = JsonParser.parseString(Files.readString(requestFile)).getAsJsonObject();
                Files.delete(requestFile);
                String command = request.get("cmd").getAsString();
                switch (command) {
                    case "status": break;
                    case "pose":
                        if (client.player == null) throw new IllegalStateException("Not connected");
                        goannaPose = request.deepCopy();
                        client.options.fov().set(request.get("fov").getAsInt());
                        client.options.fovEffectScale().set(0.0);
                        client.gui.setScreen(null);
                        if (!client.gui.hud.isHidden()) client.gui.hud.toggle();
                        client.mouseHandler.releaseMouse();
                        break;
                    case "shot":
                        goannaShot = request;
                        return;
                    case "quit": client.stop(); break;
                    default: throw new IllegalArgumentException("Unknown command: " + command);
                }
                goannaApplyPose(client);
                goannaReply(request, goannaStatus(client));
            } catch (Exception error) {
                JsonObject result = new JsonObject();
                result.addProperty("ok", false);
                result.addProperty("error", error.toString());
                goannaReply(request, result);
            }
        }
        goannaApplyPose(client);
    }

    @Unique private void goannaApplyPose(Minecraft client) {
        if (goannaPose == null || client.player == null) return;
        double x = goannaPose.get("x").getAsDouble();
        double y = goannaPose.get("y").getAsDouble() - client.player.getEyeHeight();
        double z = goannaPose.get("z").getAsDouble();
        float yaw = goannaPose.get("yaw").getAsFloat();
        float pitch = goannaPose.get("pitch").getAsFloat();
        client.player.setPos(x, y, z);
        client.player.xo = x;
        client.player.yo = y;
        client.player.zo = z;
        client.player.setYRot(yaw);
        client.player.setXRot(pitch);
        client.player.yRotO = yaw;
        client.player.xRotO = pitch;
        client.player.setDeltaMovement(0, 0, 0);
    }

    @Inject(method = "renderFrame", at = @At("TAIL"))
    private void goannaFrame(boolean renderLevel, CallbackInfo info) {
        if (goannaShot == null) return;
        Minecraft client = (Minecraft) (Object) this;
        JsonObject request = goannaShot;
        goannaShot = null;
        String name = "goanna-" + request.get("id").getAsLong() + ".png";
        JsonObject result = goannaStatus(client);
        Screenshot.grab(client.gameDirectory, name, client.gameRenderer.mainRenderTarget(), 1,
            message -> {
                result.addProperty("path", client.gameDirectory.toPath()
                    .resolve("screenshots").resolve(name).toString());
                result.addProperty("message", message.getString());
                goannaReply(request, result);
            });
    }
}
