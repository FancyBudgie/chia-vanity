use std::borrow::Cow;

use anyhow::{Context, Result};
use blstrs::G1Affine;
use num_bigint::BigUint;
use wgpu::util::DeviceExt;

use crate::{readback, storage_entry};

pub(crate) const SEARCH_BATCH_CAPACITY: u32 = 262_144;
const WORKGROUP_SIZE: u32 = 256;
const NO_HIT: u32 = u32::MAX;
const PARAM_WORDS: usize = 136;
const BECH32_CHARSET: &str = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
const G1_TABLE: &[u8] = include_bytes!("g1_table.bin");

const SHADER_PARTS: &[&str] = &[
    include_str!("shaders/types.wgsl"),
    include_str!("shaders/fp.wgsl"),
    include_str!("shaders/g1.wgsl"),
    include_str!("shaders/sha256.wgsl"),
    include_str!("shaders/scalar.wgsl"),
    include_str!("shaders/puzzle.wgsl"),
    include_str!("shaders/bech32.wgsl"),
    include_str!("shaders/filter.wgsl"),
];

pub(crate) struct NativeSearch {
    pipeline: wgpu::ComputePipeline,
    bind_group: wgpu::BindGroup,
    params_buffer: wgpu::Buffer,
    hit_buffer: wgpu::Buffer,
    staging: wgpu::Buffer,
}

impl NativeSearch {
    pub(crate) fn new(
        device: &wgpu::Device,
        account_public_key: &[u8; 48],
        account_affine: &G1Affine,
    ) -> Result<Self> {
        let source = SHADER_PARTS.join("\n");
        let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("Vanity end-to-end search shader"),
            source: wgpu::ShaderSource::Wgsl(Cow::Owned(source)),
        });
        let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("Vanity end-to-end search layout"),
            entries: &[
                storage_entry(0, true),
                storage_entry(1, true),
                storage_entry(2, true),
                storage_entry(3, false),
            ],
        });
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("Vanity end-to-end search pipeline layout"),
            bind_group_layouts: &[&layout],
            immediate_size: 0,
        });
        let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
            label: Some("Vanity end-to-end search pipeline"),
            layout: Some(&pipeline_layout),
            module: &module,
            entry_point: Some("search_kernel"),
            compilation_options: wgpu::PipelineCompilationOptions {
                constants: &[("workgroup_size_x", WORKGROUP_SIZE as f64)],
                ..Default::default()
            },
            cache: None,
        });

        let params_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Vanity search parameters"),
            size: (PARAM_WORDS * size_of::<u32>()) as u64,
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let account_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Vanity account key"),
            contents: &account_key_bytes(account_public_key, account_affine),
            usage: wgpu::BufferUsages::STORAGE,
        });
        let table_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Vanity 6-bit fixed-base table"),
            contents: G1_TABLE,
            usage: wgpu::BufferUsages::STORAGE,
        });
        let hit_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Vanity lowest hit"),
            size: size_of::<u32>() as u64,
            usage: wgpu::BufferUsages::STORAGE
                | wgpu::BufferUsages::COPY_DST
                | wgpu::BufferUsages::COPY_SRC,
            mapped_at_creation: false,
        });
        let staging = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Vanity hit readback"),
            size: size_of::<u32>() as u64,
            usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Vanity end-to-end search bind group"),
            layout: &layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: params_buffer.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: account_buffer.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: table_buffer.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 3,
                    resource: hit_buffer.as_entire_binding(),
                },
            ],
        });

        Ok(Self {
            pipeline,
            bind_group,
            params_buffer,
            hit_buffer,
            staging,
        })
    }

    pub(crate) async fn search(
        &self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        start_index: u32,
        count: u32,
        step: u32,
        address_prefix: &str,
        wanted_prefix: &str,
        wanted_suffix: &str,
    ) -> Result<Option<u32>> {
        let params = search_params(
            start_index,
            count,
            step,
            address_prefix,
            wanted_prefix,
            wanted_suffix,
        )?;
        queue.write_buffer(&self.params_buffer, 0, bytemuck::cast_slice(&params));
        queue.write_buffer(&self.hit_buffer, 0, &NO_HIT.to_le_bytes());

        let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("Vanity end-to-end search batch"),
        });
        {
            let mut pass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
                label: Some("Vanity end-to-end search batch"),
                timestamp_writes: None,
            });
            pass.set_pipeline(&self.pipeline);
            pass.set_bind_group(0, &self.bind_group, &[]);
            pass.dispatch_workgroups(count.div_ceil(WORKGROUP_SIZE), 1, 1);
        }
        encoder.copy_buffer_to_buffer(
            &self.hit_buffer,
            0,
            &self.staging,
            0,
            size_of::<u32>() as u64,
        );
        queue.submit(Some(encoder.finish()));

        let bytes = readback(device, &self.staging).await?;
        let hit = u32::from_le_bytes(
            bytes[..4]
                .try_into()
                .context("hit readback was truncated")?,
        );
        Ok((hit != NO_HIT).then_some(hit))
    }
}

fn search_params(
    start_index: u32,
    count: u32,
    step: u32,
    address_prefix: &str,
    wanted_prefix: &str,
    wanted_suffix: &str,
) -> Result<[u32; PARAM_WORDS]> {
    let mut words = [0_u32; PARAM_WORDS];
    let full_prefix = format!("{address_prefix}1");
    let wanted_prefix = wanted_prefix
        .to_ascii_lowercase()
        .strip_prefix(&full_prefix)
        .unwrap_or(wanted_prefix)
        .to_owned();
    let prefix_values = bech32_values(&wanted_prefix)?;
    let suffix_values = bech32_values(&wanted_suffix.to_ascii_lowercase())?;
    anyhow::ensure!(prefix_values.len() <= 64, "address prefix is too long");
    anyhow::ensure!(suffix_values.len() <= 58, "address suffix is too long");

    words[0] = start_index;
    words[1] = count;
    words[2] = step;
    words[3] = match address_prefix {
        "xch" => 0,
        "txch" => 1,
        _ => anyhow::bail!("unsupported Chia address prefix"),
    };
    words[4] = prefix_values.len() as u32;
    words[5] = suffix_values.len() as u32;
    words[8..8 + prefix_values.len()].copy_from_slice(&prefix_values);
    words[72..72 + suffix_values.len()].copy_from_slice(&suffix_values);
    Ok(words)
}

fn bech32_values(value: &str) -> Result<Vec<u32>> {
    value
        .chars()
        .map(|character| {
            BECH32_CHARSET
                .find(character)
                .map(|index| index as u32)
                .with_context(|| format!("invalid Bech32 character {character:?}"))
        })
        .collect()
}

fn account_key_bytes(account_public_key: &[u8; 48], account_affine: &G1Affine) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(36 * size_of::<u32>());
    bytes.extend_from_slice(account_public_key);
    let uncompressed = account_affine.to_uncompressed();
    append_montgomery_limbs(&mut bytes, &uncompressed[..48]);
    append_montgomery_limbs(&mut bytes, &uncompressed[48..]);
    bytes
}

fn append_montgomery_limbs(output: &mut Vec<u8>, coordinate: &[u8]) {
    let modulus = BigUint::parse_bytes(
        b"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab",
        16,
    )
    .expect("BLS12-381 modulus");
    let value = (BigUint::from_bytes_be(coordinate) << 384_usize) % modulus;
    let mut limbs = value.to_u32_digits();
    limbs.resize(12, 0);
    for limb in limbs {
        output.extend_from_slice(&limb.to_le_bytes());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use group::prime::PrimeCurveAffine;

    #[test]
    fn account_key_layout_contains_compressed_key_and_two_coordinates() {
        let affine = G1Affine::generator();
        let compressed = affine.to_compressed();
        let bytes = account_key_bytes(&compressed, &affine);
        assert_eq!(bytes.len(), 144);
        assert_eq!(&bytes[..48], &compressed);
        assert!(bytes[48..].iter().any(|byte| *byte != 0));
    }

    #[test]
    fn search_parameters_strip_the_human_readable_prefix() {
        let params = search_params(4, 8, 3, "xch", "xch1ace", "qq").unwrap();
        assert_eq!(&params[..6], &[4, 8, 3, 0, 3, 2]);
        assert_eq!(&params[8..11], &[29, 24, 25]);
        assert_eq!(&params[72..74], &[0, 0]);
    }
}
