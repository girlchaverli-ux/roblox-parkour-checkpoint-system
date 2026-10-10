--[[
	CheckpointManager.lua
	
	Gerencia o sistema de checkpoints para o jogo de parkour.
	Responsabilidades:
	- Detectar e configurar novos checkpoints
	- Rastrear o checkpoint atual de cada jogador
	- Salvar checkpoint ao ser ativado
	- Respeitar o spawn no checkpoint ao morrer
	
	Localização: ServerScriptService > CheckpointManager
]]

local Players = game:GetService("Players")

-- Configurações
local CONFIG = {
	CHECKPOINT_MODEL_NAME = "SpawnPoint",
	SPAWN_OFFSET_Y = 2,  -- Distância acima do checkpoint para spawnar
	RESPAWN_DELAY = 0.1, -- Delay antes de teleportar ao respawn
}

-- Estado do sistema
local checkpointStorage = {}
local configuredCheckpoints = {}

--[[
	Obtém a posição de spawn para um checkpoint
	
	Prioridades:
	1. Parte nomeada "Spawn"
	2. PrimaryPart do modelo
	3. Centro do bounding box
]]
local function getSpawnPosition(checkpointModel)
	-- Tenta usar uma parte específica de spawn
	local spawnPart = checkpointModel:FindFirstChild("Spawn")
	if spawnPart and spawnPart:IsA("BasePart") then
		return spawnPart.Position + Vector3.new(0, CONFIG.SPAWN_OFFSET_Y, 0)
	end

	-- Tenta usar o PrimaryPart
	if checkpointModel.PrimaryPart and checkpointModel.PrimaryPart:IsA("BasePart") then
		return checkpointModel.PrimaryPart.Position + Vector3.new(0, CONFIG.SPAWN_OFFSET_Y, 0)
	end

	-- Fallback: usa o bounding box
	local boundingCFrame, boundingSize = checkpointModel:GetBoundingBox()
	return boundingCFrame.Position + Vector3.new(0, boundingSize.Y / 2 + CONFIG.SPAWN_OFFSET_Y, 0)
end

--[[
	Ativa um checkpoint para um jogador
	
	Responsabilidades:
	- Salvar o checkpoint como o atual do jogador
	- Disparar o evento de ativação (som + efeitos)
	- Enviar requisição para o ParticleSystem
]]
local function activateCheckpoint(player, checkpointModel)
	if not player or not checkpointModel or not checkpointModel.Parent then
		warn("[CheckpointManager] Tentativa inválida de ativar checkpoint")
		return
	end

	-- Evita ativar o mesmo checkpoint duas vezes
	if checkpointStorage[player] == checkpointModel then
		return
	end

	-- Salva o checkpoint como atual
	checkpointStorage[player] = checkpointModel

	print("[CheckpointManager] " .. player.Name .. " ativou checkpoint: " .. checkpointModel.Name)

	-- Dispara os efeitos (som + partículas)
	-- Usa a função do ParticleSystem se disponível
	local particleSystem = game:GetService("ServerScriptService"):FindFirstChild("ParticleSystem")
	if particleSystem then
		local playEffects = particleSystem:FindFirstChild("PlayEffects")
		if playEffects and playEffects:IsA("BindableFunction") then
			task.spawn(function()
				local success, err = pcall(function()
					playEffects:Invoke(checkpointModel, player)
				end)
				if not success then
					warn("[CheckpointManager] Erro ao chamar ParticleSystem: " .. tostring(err))
				end
			end)
		end
	end
end

--[[
	Configura um checkpoint individual
	
	- Encontra as partes de colisão
	- Conecta listeners de Touched
	- Marca como configurado
]]
local function setupCheckpoint(checkpointModel)
	if not checkpointModel or not checkpointModel:IsA("Model") then
		return
	end

	if checkpointModel.Name ~= CONFIG.CHECKPOINT_MODEL_NAME then
		return
	end

	-- Evita configurar o mesmo checkpoint duas vezes
	if configuredCheckpoints[checkpointModel] then
		return
	end

	configuredCheckpoints[checkpointModel] = true

	-- Encontra todas as partes de colisão (exclui Star e Particula)
	local touchParts = {}
	for _, descendant in ipairs(checkpointModel:GetDescendants()) do
		if descendant:IsA("BasePart") then
			if descendant.Name ~= "Star" and descendant.Name ~= "Particula" then
				table.insert(touchParts, descendant)
			end
		end
	end

	-- Se não houver partes de colisão, avisa
	if #touchParts == 0 then
		warn("[CheckpointManager] Checkpoint sem partes de colisão: " .. checkpointModel:GetFullName())
		return
	end

	-- Conecta cada parte a um listener Touched
	for _, part in ipairs(touchParts) do
		part.Touched:Connect(function(hit)
			-- Verifica se é um personagem
			local character = hit.Parent
			if not character or not character:FindFirstChildOfClass("Humanoid") then
				return
			end

			-- Obtém o player
			local player = Players:GetPlayerFromCharacter(character)
			if not player then
				return
			end

			-- Ativa o checkpoint
			activateCheckpoint(player, checkpointModel)
		end)
	end

	print("[CheckpointManager] Checkpoint configurado: " .. checkpointModel.Name)
end

--[[
	Ao respawnar, teleporta o jogador para o último checkpoint salvo
]]
local function handleCharacterRespawn(player, character)
	local checkpointModel = checkpointStorage[player]

	-- Se não houver checkpoint salvo, não faz nada
	if not checkpointModel or not checkpointModel.Parent then
		return
	end

	-- Aguarda a existência do HumanoidRootPart
	local humanoidRootPart = character:FindFirstChild("HumanoidRootPart", false)
	if not humanoidRootPart then
		humanoidRootPart = character:WaitForChild("HumanoidRootPart", 5)
		if not humanoidRootPart then
			warn("[CheckpointManager] HumanoidRootPart não encontrado para " .. player.Name)
			return
		end
	end

	-- Aguarda um pouco antes de teleportar (garante que o personagem foi totalmente carregado)
	task.wait(CONFIG.RESPAWN_DELAY)

	-- Verifica novamente se o checkpoint ainda é válido
	if not checkpointModel or not checkpointModel.Parent or not humanoidRootPart.Parent then
		return
	end

	-- Teleporta o jogador para o checkpoint
	local spawnPosition = getSpawnPosition(checkpointModel)
	character:PivotTo(CFrame.new(spawnPosition))

	print("[CheckpointManager] " .. player.Name .. " respawned no checkpoint: " .. checkpointModel.Name)
end

--[[
	Configura um jogador recém-entrado
	
	- Conecta evento de respawn
	- Respeita o checkpoint se ele já tiver um personagem
]]
local function setupPlayer(player)
	-- Conecta o evento de novo personagem
	player.CharacterAdded:Connect(function(character)
		handleCharacterRespawn(player, character)
	end)

	-- Se o jogador já tiver um personagem (reload), respeita o checkpoint
	if player.Character then
		task.defer(handleCharacterRespawn, player, player.Character)
	end
end

--[[
	Limpa os dados do jogador ao sair
]]
local function handlePlayerLeaving(player)
	checkpointStorage[player] = nil
end

-- ============================================================
-- INICIALIZAÇÃO DO SISTEMA
-- ============================================================

-- Varre os checkpoints já existentes no workspace
for _, object in ipairs(workspace:GetDescendants()) do
	if object:IsA("Model") and object.Name == CONFIG.CHECKPOINT_MODEL_NAME then
		task.defer(setupCheckpoint, object)
	end
end

-- Detecta novos checkpoints criados em tempo de execução
workspace.DescendantAdded:Connect(function(object)
	if object:IsA("Model") and object.Name == CONFIG.CHECKPOINT_MODEL_NAME then
		task.defer(setupCheckpoint, object)
	end
end)

-- Conecta novos jogadores
Players.PlayerAdded:Connect(setupPlayer)

-- Conecta jogadores que já estão no servidor (se o script for recarregado)
for _, player in ipairs(Players:GetPlayers()) do
	task.defer(setupPlayer, player)
end

-- Limpa dados ao jogador sair
Players.PlayerRemoving:Connect(handlePlayerLeaving)

print("[CheckpointManager] Sistema inicializado com sucesso!")
