// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 the Goanna contributors
import com.mojang.blaze3d.platform.NativeImage;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;
import net.minecraft.client.renderer.texture.MipmapGenerator;
import net.minecraft.client.renderer.texture.MipmapStrategy;
import net.minecraft.resources.Identifier;

/** Run the installed game's mipmap generator without starting a renderer. */
public class MipmapProbe {
    public static void main(String[] args) throws Exception {
        Path out = Path.of(args[1]);
        Files.createDirectories(out);
        NativeImage image = NativeImage.read(Files.readAllBytes(Path.of(args[0])));
        NativeImage[] levels = MipmapGenerator.generateMipLevels(
            Identifier.parse(args[2]), new NativeImage[]{image},
            Integer.parseInt(args[5]),
            MipmapStrategy.valueOf(args[3].toUpperCase(Locale.ROOT)),
            Float.parseFloat(args[4]), image.computeTransparency());
        try {
            for (int level = 0; level < levels.length; ++level) {
                levels[level].writeToFile(out.resolve("mip-" + level + ".png"));
            }
        } finally {
            for (NativeImage level : levels) {
                level.close();
            }
        }
    }
}
